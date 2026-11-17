using System.Text.Json;

namespace BlobProcessing;

public sealed record BlobCreatedEvent(string BlobName, Uri BlobUri, DateTimeOffset EventTime, string? ETag, string? Sequencer);

public static class BlobCreatedEventParser
{
    private const string SubjectPrefix = "/blobServices/default/containers/uploads/blobs/";

    public static BlobCreatedEvent Parse(string message, Uri trustedServiceUri)
    {
        try
        {
            using var document = JsonDocument.Parse(message);
            var root = document.RootElement;
            if (root.ValueKind == JsonValueKind.Array)
            {
                if (root.GetArrayLength() != 1)
                    throw new InvalidEventException("Expected exactly one event.");
                root = root[0];
            }

            if (root.GetProperty("eventType").GetString() != "Microsoft.Storage.BlobCreated")
                throw new InvalidEventException("Expected a BlobCreated event.");
            var subject = root.GetProperty("subject").GetString();
            if (subject is null || !subject.StartsWith(SubjectPrefix, StringComparison.Ordinal) || subject.Length == SubjectPrefix.Length)
                throw new InvalidEventException("Expected a blob in the uploads container.");

            var name = subject[SubjectPrefix.Length..];
            var data = root.GetProperty("data");
            var url = data.GetProperty("url").GetString();
            if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)
                || uri.Scheme != Uri.UriSchemeHttps
                || !string.Equals(uri.Host, trustedServiceUri.Host, StringComparison.OrdinalIgnoreCase)
                || uri.Port != trustedServiceUri.Port
                || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0
                || Uri.UnescapeDataString(uri.AbsolutePath) != "/uploads/" + name)
                throw new InvalidEventException("Blob URL does not match the trusted account and subject.");

            var eventTime = root.GetProperty("eventTime").GetDateTimeOffset();
            return new BlobCreatedEvent(name, uri, eventTime, OptionalString(data, "eTag"), OptionalString(data, "sequencer"));
        }
        catch (InvalidEventException)
        {
            throw;
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or ArgumentException)
        {
            throw new InvalidEventException("Event is malformed.", exception);
        }
    }

    private static string? OptionalString(JsonElement data, string name)
    {
        if (!data.TryGetProperty(name, out var value))
            return null;
        var result = value.GetString();
        if (string.IsNullOrWhiteSpace(result))
            throw new InvalidEventException($"Event {name} must be a non-empty string.");
        return result;
    }
}

public sealed class InvalidEventException : Exception
{
    public InvalidEventException(string message) : base(message) { }
    public InvalidEventException(string message, Exception innerException) : base(message, innerException) { }
}
