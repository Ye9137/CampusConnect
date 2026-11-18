namespace CampusConnect;

internal sealed record StoredConnection(CampusProfile Profile, string ProtectedPassword);
internal sealed record UserConnection(CampusProfile Profile, string Password);

// Keep the legacy active fields so existing installations can migrate without losing credentials.
internal sealed record ConnectionConfiguration(CampusProfile Profile, string ProtectedPassword,
    Dictionary<string, StoredConnection>? Profiles = null)
{
    internal const string BackupWifiKey = "wifi-backup";

    internal ConnectionConfiguration WithBackupWifi(StoredConnection? backup)
    {
        var entries = AllProfiles();
        if (backup is null) entries.Remove(BackupWifiKey);
        else entries[BackupWifiKey] = backup;
        return this with { Profiles = entries };
    }

    internal Dictionary<string, StoredConnection> AllProfiles()
    {
        var result = Profiles is null ? new Dictionary<string, StoredConnection>() : new(Profiles);
        result[Key(Profile)] = new(Profile, ProtectedPassword);
        return result;
    }
    internal ConnectionConfiguration WithActive(CampusProfile profile, string protectedPassword)
    {
        var entries = AllProfiles();
        entries[Key(profile)] = new(profile, protectedPassword);
        return new(profile, protectedPassword, entries);
    }
    internal static string Key(CampusProfile profile) => profile.IsWired ? "wired" : "wifi";
    internal static CampusProfile Empty(bool wired) => new() { ConnectionMode = wired ? "wired" : "wifi", Ssid = "", PortalUrl = "" };
}
