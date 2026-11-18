using Microsoft.Azure.Functions.Worker.Extensions.Abstractions;

// The Worker SDK builds the host's extensions from ExtensionInformation attributes: the function app's bindings first,
// then its references, the last one for a package winning. Worker.Extensions.Storage.Blobs 6.8.2, the latest, brings
// Microsoft.Azure.WebJobs.Extensions.Storage.Blobs 5.3.8, whose container scan stops seeing new blobs when Storage
// Analytics logs are off; 5.3.10 fixes it (azure-sdk-for-net #61660, #62763; docs/experiments, Q4).
[assembly: ExtensionInformation("Microsoft.Azure.WebJobs.Extensions.Storage.Blobs", "5.3.10", true)]
