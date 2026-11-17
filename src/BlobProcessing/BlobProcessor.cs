using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Extensions.Logging;

namespace BlobProcessing;

public sealed class BlobProcessor(IProcessedStore processedStore, ILogger<BlobProcessor> logger)
{
    public async Task ProcessAsync(BlobClient blob, string app, string trigger, string invocationId,
        DateTimeOffset eventTime, CancellationToken cancellationToken, string? eventETag = null)
    {
        var started = DateTimeOffset.UtcNow;
        var properties = (await blob.GetPropertiesAsync(cancellationToken: cancellationToken)).Value;
        var version = properties.VersionId ?? properties.ETag.ToString();
        var key = Idempotency.Key(blob.AccountName, blob.Name, version);
        using var scope = logger.BeginScope(new Dictionary<string, object?>
        {
            ["app"] = app,
            ["trigger"] = trigger,
            ["blobName"] = blob.Name,
            ["uri"] = blob.Uri.ToString(),
            ["size"] = properties.ContentLength,
            ["etag"] = properties.ETag.ToString(),
            ["versionId"] = properties.VersionId,
            ["eventTime"] = eventTime,
            ["processingStart"] = started,
            ["podName"] = Environment.GetEnvironmentVariable("POD_NAME") ?? "local",
            ["invocationId"] = invocationId,
            ["idempotencyKey"] = key
        });
        if (!EventETagMatches(eventETag, properties.ETag))
        {
            logger.LogInformation("Blob event superseded: eventETag={eventETag}, currentETag={currentETag}",
                eventETag, properties.ETag.ToString());
            return;
        }
        logger.LogInformation("Blob properties read; processing started");

        if (properties.ContentLength > 0)
        {
            var options = new BlobDownloadOptions
            {
                Range = new HttpRange(0, Math.Min(1024, properties.ContentLength)),
                Conditions = new BlobRequestConditions { IfMatch = properties.ETag }
            };
            Response<BlobDownloadStreamingResult> download;
            try
            {
                download = await blob.DownloadStreamingAsync(options, cancellationToken);
            }
            catch (RequestFailedException exception) when (eventETag is not null && exception.Status == 412)
            {
                logger.LogInformation("Blob event superseded during read: eventETag={eventETag}", eventETag);
                return;
            }
            await using var content = download.Value.Content;
            await content.CopyToAsync(Stream.Null, cancellationToken);
        }
        logger.LogInformation("Blob prefix read");
        var duplicate = !await processedStore.TryInsertAsync(app, key, cancellationToken);
        var ended = DateTimeOffset.UtcNow;
        logger.LogInformation("Blob processing finished: duplicate={duplicate}, processingEnd={processingEnd}, latencyMs={latencyMs}",
            duplicate, ended, (ended - properties.CreatedOn).TotalMilliseconds);
    }

    private static bool EventETagMatches(string? eventETag, ETag currentETag) =>
        eventETag is null ||
        string.Equals(eventETag.Trim('"'), currentETag.ToString().Trim('"'), StringComparison.Ordinal);
}
