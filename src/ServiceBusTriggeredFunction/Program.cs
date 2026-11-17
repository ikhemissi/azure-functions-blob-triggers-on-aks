using BlobProcessing;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);
FunctionServices.Configure(builder);
builder.Build().Run();
