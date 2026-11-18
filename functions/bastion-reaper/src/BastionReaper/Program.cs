using Azure.Identity;
using Azure.Monitor.OpenTelemetry.Exporter;
using Azure.ResourceManager;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenTelemetry;

var builder = FunctionsApplication.CreateBuilder(args);

// In Azure, the app's user-assigned identity (AZURE_CLIENT_ID); locally, the Azure CLI's sign-in.
var credential = new DefaultAzureCredential();

// The exporter needs the credential: Application Insights accepts only Entra-authenticated telemetry, and the worker's
// exporter doesn't read the host's APPLICATIONINSIGHTS_AUTHENTICATION_STRING.
builder.Services.AddOpenTelemetry()
    .UseFunctionsWorkerDefaults()
    .UseAzureMonitorExporter(options => options.Credential = credential);

builder.Services.AddSingleton(new ArmClient(credential));

builder.Build().Run();
