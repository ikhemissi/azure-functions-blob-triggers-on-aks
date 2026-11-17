using Azure.Storage.Blobs;
using BlobProcessing;
using Microsoft.Azure.Functions.Worker;

namespace BlobPollingFunction;

public sealed class BlobPolling(BlobProcessor processor)
{
    [Function(nameof(BlobPolling))]
    public Task RunAsync(
        [BlobTrigger("uploads/{name}", Connection = "UploadsStorage")] BlobClient blob,
        FunctionContext context, CancellationToken cancellationToken) =>
        processor.ProcessAsync(blob, "blob-polling", "blob-polling", context.InvocationId,
            DateTimeOffset.UtcNow, cancellationToken);
}
