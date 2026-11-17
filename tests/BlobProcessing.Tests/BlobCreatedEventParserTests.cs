namespace BlobProcessing.Tests;

public class BlobCreatedEventParserTests
{
    private static readonly Uri TrustedService = new("https://sample.blob.core.windows.net/");
    private const string ValidEvent = """
        {"eventType":"Microsoft.Storage.BlobCreated",
         "subject":"/blobServices/default/containers/uploads/blobs/dir/test.txt",
         "eventTime":"2026-01-01T00:00:00Z",
         "data":{"url":"https://sample.blob.core.windows.net/uploads/dir/test.txt",
                 "eTag":"0x123","sequencer":"000001"}}
        """;

    [Fact]
    public void ValidBlobCreatedEventIsParsed()
    {
        var result = BlobCreatedEventParser.Parse(ValidEvent, TrustedService);

        Assert.Equal("dir/test.txt", result.BlobName);
        Assert.Equal("0x123", result.ETag);
        Assert.Equal("000001", result.Sequencer);
        Assert.Equal(new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero), result.EventTime);
    }

    [Theory]
    [InlineData("Microsoft.Storage.BlobCreated", "Microsoft.Storage.BlobDeleted")]
    [InlineData("/containers/uploads/", "/containers/other/")]
    [InlineData("https://sample.blob.core.windows.net/", "https://other.blob.core.windows.net/")]
    [InlineData("/uploads/dir/test.txt", "/other/dir/test.txt")]
    [InlineData("https://sample.blob.core.windows.net/", "http://sample.blob.core.windows.net/")]
    public void InvalidEventIsRejected(string original, string replacement)
    {
        var message = ValidEvent.Replace(original, replacement, StringComparison.Ordinal);

        Assert.Throws<InvalidEventException>(() => BlobCreatedEventParser.Parse(message, TrustedService));
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("{}")]
    public void MalformedMessageIsRejected(string message)
    {
        Assert.Throws<InvalidEventException>(() => BlobCreatedEventParser.Parse(message, TrustedService));
    }
}
