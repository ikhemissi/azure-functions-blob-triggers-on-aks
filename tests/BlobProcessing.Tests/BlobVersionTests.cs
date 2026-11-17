using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Extensions.Logging;

namespace BlobProcessing.Tests;

public class BlobVersionTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("0x123")]
    [InlineData("\"0x123\"")]
    public async Task MissingOrMatchingEventETagProcessesCurrentVersion(string? eventETag)
    {
        var blob = new FakeBlobClient("\"0x123\"", 0);
        var store = new FakeProcessedStore();
        var processor = new BlobProcessor(store, new FakeLogger());

        await processor.ProcessAsync(blob, "queue-triggered", "storage-queue", "invocation",
            DateTimeOffset.UtcNow, CancellationToken.None, eventETag);

        Assert.True(store.Inserted);
    }

    [Fact]
    public async Task SupersededEventIsLoggedAndCompletedWithoutReadingOrRecordingNewVersion()
    {
        var blob = new FakeBlobClient("\"0x456\"", 100);
        var store = new FakeProcessedStore();
        var logger = new FakeLogger();
        var processor = new BlobProcessor(store, logger);

        await processor.ProcessAsync(blob, "queue-triggered", "storage-queue", "invocation",
            DateTimeOffset.UtcNow, CancellationToken.None, "0x123");

        Assert.False(blob.DownloadAttempted);
        Assert.False(store.Inserted);
        Assert.Contains(logger.Messages, message => message.Contains("superseded", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("0x123", true)]
    [InlineData(null, false)]
    public async Task OverwriteDuringReadCompletesOnlyEventBasedInvocations(string? eventETag, bool completes)
    {
        var blob = new FakeBlobClient("\"0x123\"", 100);
        var store = new FakeProcessedStore();
        var logger = new FakeLogger();
        var processor = new BlobProcessor(store, logger);

        var processing = processor.ProcessAsync(blob, "queue-triggered", "storage-queue", "invocation",
            DateTimeOffset.UtcNow, CancellationToken.None, eventETag);

        if (completes)
        {
            await processing;
            Assert.Contains(logger.Messages, message => message.Contains("superseded", StringComparison.Ordinal));
        }
        else
        {
            var exception = await Assert.ThrowsAsync<RequestFailedException>(() => processing);
            Assert.Equal(412, exception.Status);
        }
        Assert.True(blob.DownloadAttempted);
        Assert.False(store.Inserted);
    }

    private sealed class FakeBlobClient(string etag, long length)
        : BlobClient(new Uri("https://sample.blob.core.windows.net/uploads/test.txt"))
    {
        public bool DownloadAttempted { get; private set; }

        public override Task<Response<BlobProperties>> GetPropertiesAsync(
            BlobRequestConditions? conditions = null, CancellationToken cancellationToken = default)
        {
            var properties = BlobsModelFactory.BlobProperties(eTag: new ETag(etag), contentLength: length);
            return Task.FromResult(Response.FromValue(properties, null!));
        }

        public override Task<Response<BlobDownloadStreamingResult>> DownloadStreamingAsync(
            BlobDownloadOptions options, CancellationToken cancellationToken = default)
        {
            DownloadAttempted = true;
            throw new RequestFailedException(412, "Blob was overwritten.");
        }
    }

    private sealed class FakeProcessedStore : IProcessedStore
    {
        public bool Inserted { get; private set; }

        public Task<bool> TryInsertAsync(string app, string key, CancellationToken cancellationToken)
        {
            Inserted = true;
            return Task.FromResult(true);
        }
    }

    private sealed class FakeLogger : ILogger<BlobProcessor>
    {
        public List<string> Messages { get; } = [];

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter) => Messages.Add(formatter(state, exception));
    }
}
