using System.Security.Cryptography;
using System.Text;
using Azure;
using Azure.Data.Tables;

namespace BlobProcessing;

public static class Idempotency
{
    public static string Key(string account, string blobName, string version) =>
        $"{account}/uploads/{blobName}/{version}/process";

    public static string RowKey(string key) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(key)));
}

public interface IProcessedStore
{
    Task<bool> TryInsertAsync(string app, string key, CancellationToken cancellationToken);
}

public sealed class ProcessedTableStore(TableClient table) : IProcessedStore
{
    public async Task<bool> TryInsertAsync(string app, string key, CancellationToken cancellationToken)
    {
        try
        {
            await table.AddEntityAsync(new TableEntity(app, Idempotency.RowKey(key)), cancellationToken);
            return true;
        }
        catch (RequestFailedException exception) when (exception.Status == 409)
        {
            return false;
        }
    }
}
