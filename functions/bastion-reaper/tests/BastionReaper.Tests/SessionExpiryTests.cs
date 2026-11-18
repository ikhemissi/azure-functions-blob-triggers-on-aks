namespace BastionReaper.Tests;

public class SessionExpiryTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 17, 12, 0, 0, TimeSpan.Zero);

    private static bool IsDue(params (string Key, string Value)[] tags) =>
        SessionExpiry.IsDue(tags.ToDictionary(tag => tag.Key, tag => tag.Value), Now, out _);

    [Fact]
    public void A_session_whose_time_has_passed_is_due() =>
        Assert.True(IsDue(("delete-after", "2026-11-17T11:59:59Z")));

    [Fact]
    public void A_session_is_due_at_its_exact_time() =>
        Assert.True(IsDue(("delete-after", "2026-11-17T12:00:00Z")));

    [Fact]
    public void A_session_whose_time_is_ahead_is_kept() =>
        Assert.False(IsDue(("delete-after", "2026-11-17T12:00:01Z")));

    [Fact]
    public void A_time_with_an_offset_is_compared_in_UTC() =>
        Assert.False(IsDue(("delete-after", "2026-11-17T13:30:00+01:00")));

    [Fact]
    public void A_time_without_a_zone_is_read_as_UTC() =>
        Assert.True(IsDue(("delete-after", "2026-11-17T11:00:00")));

    [Fact]
    public void A_resource_without_the_tag_is_due()
    {
        Assert.True(SessionExpiry.IsDue(new Dictionary<string, string> { ["azd-env-name"] = "dev" }, Now, out var reason));
        Assert.Equal("no delete-after tag", reason);
    }

    [Fact]
    public void A_resource_with_an_unreadable_tag_is_due()
    {
        Assert.True(SessionExpiry.IsDue(new Dictionary<string, string> { ["delete-after"] = "tomorrow" }, Now, out var reason));
        Assert.Equal("unreadable delete-after tag 'tomorrow'", reason);
    }
}
