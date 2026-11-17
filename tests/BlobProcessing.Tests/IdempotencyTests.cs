using Azure;
using Azure.Data.Tables;

namespace BlobProcessing.Tests;

public class IdempotencyTests
{
    [Fact]
    public void KeyAndRowKeyAreDeterministic()
    {
        var key = Idempotency.Key("sample", "dir/test.txt", "\"0x123\"");

        Assert.Equal("sample/uploads/dir/test.txt/\"0x123\"/process", key);
        Assert.Equal("f284ecd44782568b359701ba73cb47033c89e54b1344902f08605f73c87cd9c0", Idempotency.RowKey(key));
    }

    [Fact]
    public async Task ConflictMeansDuplicate()
    {
        var client = new FakeTableClient(409);
        var store = new ProcessedTableStore(client);

        var inserted = await store.TryInsertAsync("queue-triggered", "key", CancellationToken.None);

        Assert.False(inserted);
        Assert.Equal("queue-triggered", client.Entity!.PartitionKey);
        Assert.Equal(Idempotency.RowKey("key"), client.Entity.RowKey);
    }

    [Fact]
    public async Task OtherTableFailuresAreRetried()
    {
        var store = new ProcessedTableStore(new FakeTableClient(503));

        await Assert.ThrowsAsync<RequestFailedException>(() =>
            store.TryInsertAsync("queue-triggered", "key", CancellationToken.None));
    }

    [Fact]
    public async Task SuccessfulInsertIsNotDuplicate()
    {
        var store = new ProcessedTableStore(new FakeTableClient(null));

        Assert.True(await store.TryInsertAsync("queue-triggered", "key", CancellationToken.None));
    }

    private sealed class FakeTableClient(int? status) : TableClient
    {
        public ITableEntity? Entity { get; private set; }

        public override Task<Response> AddEntityAsync<T>(T entity, CancellationToken cancellationToken = default)
        {
            Entity = entity;
            if (status.HasValue)
                throw new RequestFailedException(status.Value, "Simulated failure");
            return Task.FromResult<Response>(null!);
        }
    }
}
