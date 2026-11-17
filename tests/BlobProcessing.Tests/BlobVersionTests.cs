using Azure;

namespace BlobProcessing.Tests;

public class BlobVersionTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("0x123")]
    [InlineData("\"0x123\"")]
    public void MissingOrMatchingEventETagAcceptsCurrentVersion(string? eventETag)
    {
        BlobProcessor.VerifyEventETag(eventETag, new ETag("\"0x123\""));
    }

    [Fact]
    public void OverwrittenBlobIsNotProcessedAsTheOlderEvent()
    {
        Assert.Throws<InvalidOperationException>(() =>
            BlobProcessor.VerifyEventETag("0x123", new ETag("\"0x456\"")));
    }
}
