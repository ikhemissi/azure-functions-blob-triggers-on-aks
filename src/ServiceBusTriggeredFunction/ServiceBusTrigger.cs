using Azure.Identity;
using Azure.Messaging.ServiceBus;
using BlobProcessing;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace ServiceBusTriggeredFunction;

public sealed class ServiceBusTrigger(BlobProcessor processor, DefaultAzureCredential credential, ILogger<ServiceBusTrigger> logger)
{
    [Function(nameof(ServiceBusTrigger))]
    public async Task RunAsync(
        [ServiceBusTrigger("blob-events", Connection = "BlobEventsServiceBus", AutoCompleteMessages = false)] ServiceBusReceivedMessage message,
        ServiceBusMessageActions actions, FunctionContext context, CancellationToken cancellationToken)
    {
        BlobCreatedEvent blobEvent;
        try
        {
            blobEvent = BlobCreatedEventParser.Parse(message.Body.ToString(), FunctionServices.UploadsServiceUri());
        }
        catch (InvalidEventException exception)
        {
            logger.LogWarning("Malformed event dead-lettered: {reason} podName={podName} invocationId={invocationId}",
                exception.Message, Environment.GetEnvironmentVariable("POD_NAME") ?? "local", context.InvocationId);
            await actions.DeadLetterMessageAsync(message, deadLetterReason: "MalformedEvent",
                deadLetterErrorDescription: exception.Message, cancellationToken: cancellationToken);
            return;
        }

        await processor.ProcessAsync(FunctionServices.BlobFor(blobEvent, credential), "servicebus-triggered",
            "service-bus", context.InvocationId, blobEvent.EventTime, cancellationToken);
        await actions.CompleteMessageAsync(message, cancellationToken);
    }
}
