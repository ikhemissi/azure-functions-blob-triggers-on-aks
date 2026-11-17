using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Extensions.Logging;

namespace BlobProcessing;

public sealed class BlobProcessor(IProcessedStore processedStore, ILogger<BlobProcessor> logger)
{
    public async Task ProcessAsync(BlobClient blob, string app, string trigger, string invocationId,
        DateTimeOffset eventTime, CancellationToken cancellationToken)
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

        if (properties.ContentLength > 0)
        {
            var options = new BlobDownloadOptions
            {
                Range = new HttpRange(0, Math.Min(1024, properties.ContentLength)),
                Conditions = new BlobRequestConditions { IfMatch = properties.ETag }
            };
            var download = await blob.DownloadStreamingAsync(options, cancellationToken);
            await using var content = download.Value.Content;
            await content.CopyToAsync(Stream.Null, cancellationToken);
        }
        var duplicate = !await processedStore.TryInsertAsync(app, key, cancellationToken);
        var ended = DateTimeOffset.UtcNow;
        logger.LogInformation("Blob processing finished: duplicate={duplicate}, processingEnd={processingEnd}, latencyMs={latencyMs}",
            duplicate, ended, (ended - properties.CreatedOn).TotalMilliseconds);
    }
}
