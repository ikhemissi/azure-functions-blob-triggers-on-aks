using Azure.Data.Tables;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.Exporter;
using Azure.Storage.Blobs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using OpenTelemetry;
using OpenTelemetry.Logs;
using OpenTelemetry.Resources;

namespace BlobProcessing;

public static class FunctionServices
{
    public static void Configure(FunctionsApplicationBuilder builder)
    {
        var credential = new DefaultAzureCredential();
        builder.Services.AddSingleton(credential);
        builder.Services.AddSingleton<IProcessedStore>(_ =>
        {
            var tableUri = new Uri(RequiredSetting("PROCESSED_TABLE_URI"));
            if (tableUri.Scheme != Uri.UriSchemeHttps || tableUri.AbsolutePath != "/processed" ||
                tableUri.Query.Length != 0 || tableUri.Fragment.Length != 0 || tableUri.UserInfo.Length != 0)
                throw new InvalidOperationException("PROCESSED_TABLE_URI must be an HTTPS processed table URI.");
            var serviceUri = new Uri(tableUri.GetLeftPart(UriPartial.Authority));
            return new ProcessedTableStore(new TableClient(serviceUri, "processed", credential));
        });
        builder.Services.AddSingleton<BlobProcessor>();
        builder.Logging.ClearProviders();
        builder.Logging.AddJsonConsole(options => options.IncludeScopes = true);
        builder.Services.Configure<OpenTelemetryLoggerOptions>(options => options.IncludeScopes = true);
        builder.Services.AddOpenTelemetry()
            .ConfigureResource(resource => resource.AddAttributes(new Dictionary<string, object>
            {
                ["podName"] = Environment.GetEnvironmentVariable("POD_NAME") ?? "local"
            }))
            .UseFunctionsWorkerDefaults()
            .UseAzureMonitorExporter(options => options.Credential = credential);
    }

    public static BlobClient BlobFor(BlobCreatedEvent blobEvent, DefaultAzureCredential credential) =>
        new(blobEvent.BlobUri, credential);

    public static Uri UploadsServiceUri()
    {
        var uri = new Uri(RequiredSetting("UPLOADS_BLOB_SERVICE_URI"));
        if (uri.Scheme != Uri.UriSchemeHttps || uri.UserInfo.Length != 0 ||
            uri.Query.Length != 0 || uri.Fragment.Length != 0 || uri.AbsolutePath != "/")
            throw new InvalidOperationException("UPLOADS_BLOB_SERVICE_URI must be an HTTPS blob service endpoint.");
        return uri;
    }

    private static string RequiredSetting(string name) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } value
            ? value
            : throw new InvalidOperationException($"Missing required setting {name}.");
}
