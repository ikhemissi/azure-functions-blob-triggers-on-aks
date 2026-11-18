using System.Globalization;

namespace BastionReaper;

/// <summary>
/// Whether a session's resource is due for deletion, from its delete-after tag.
/// A missing or unreadable tag counts as due, so that a session nobody tagged does not stay billed.
/// </summary>
public static class SessionExpiry
{
    public const string DeleteAfterTag = "delete-after";

    public static bool IsDue(IDictionary<string, string> tags, DateTimeOffset now, out string reason)
    {
        if (!tags.TryGetValue(DeleteAfterTag, out var value))
        {
            reason = $"no {DeleteAfterTag} tag";
            return true;
        }

        if (!DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var deleteAfter))
        {
            reason = $"unreadable {DeleteAfterTag} tag '{value}'";
            return true;
        }

        reason = $"{DeleteAfterTag} {deleteAfter.UtcDateTime:yyyy-MM-ddTHH:mm:ssZ}";
        return deleteAfter <= now;
    }
}
