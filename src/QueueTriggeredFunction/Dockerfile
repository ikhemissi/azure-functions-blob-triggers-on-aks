FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/BlobProcessing/ src/BlobProcessing/
COPY src/QueueTriggeredFunction/ src/QueueTriggeredFunction/
RUN dotnet publish src/QueueTriggeredFunction/QueueTriggeredFunction.csproj -c Release -o /out

# Pin this tag to a verified digest at deployment.
FROM mcr.microsoft.com/azure-functions/dotnet-isolated:4-dotnet-isolated10.0
ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true
COPY --from=build /out/ /home/site/wwwroot/
