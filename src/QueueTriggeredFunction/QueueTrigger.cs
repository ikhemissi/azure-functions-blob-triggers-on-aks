using Azure.Identity;
using BlobProcessing;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace QueueTriggeredFunction;

public sealed class QueueTrigger(BlobProcessor processor, DefaultAzureCredential credential, ILogger<QueueTrigger> logger)
{
    [Function(nameof(QueueTrigger))]
    public async Task RunAsync([QueueTrigger("blob-events", Connection = "BlobEventsQueue")] string message,
        FunctionContext context, CancellationToken cancellationToken)
    {
        BlobCreatedEvent blobEvent;
        try
        {
            blobEvent = BlobCreatedEventParser.Parse(message, FunctionServices.UploadsServiceUri());
        }
        catch (InvalidEventException exception)
        {
            logger.LogWarning("Malformed event completed: {reason} podName={podName} invocationId={invocationId}",
                exception.Message, Environment.GetEnvironmentVariable("POD_NAME") ?? "local", context.InvocationId);
            return;
        }

        await processor.ProcessAsync(FunctionServices.BlobFor(blobEvent, credential), "queue-triggered",
            "storage-queue", context.InvocationId, blobEvent.EventTime, cancellationToken);
    }
}
