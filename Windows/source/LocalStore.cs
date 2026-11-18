using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CampusConnect;

internal static class LocalStore
{
    public static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CampusConnect");
    private static ConnectionConfiguration? Read(string directory) => File.Exists(Path.Combine(directory, "configuration.json"))
        ? JsonSerializer.Deserialize<ConnectionConfiguration>(File.ReadAllText(Path.Combine(directory, "configuration.json")))
            ?? throw new InvalidDataException("配置文件为空。") : null;
    private static string Unprotect(string value) => string.IsNullOrEmpty(value) ? "" : Encoding.UTF8.GetString(
        ProtectedData.Unprotect(Convert.FromBase64String(value), null, DataProtectionScope.CurrentUser));

    public static (CampusProfile Profile, string Password, UserConnection? Backup) Load()
    {
        var config = Read(DirectoryPath);
        var (profile, password) = Active(config);
        var stored = config?.Profiles?.GetValueOrDefault(ConnectionConfiguration.BackupWifiKey);
        return (profile, password, stored is null ? null : new(stored.Profile, Unprotect(stored.ProtectedPassword)));
    }
    internal static (CampusProfile Profile, string Password) LoadFrom(string directory) => Active(Read(directory));
    private static (CampusProfile Profile, string Password) Active(ConnectionConfiguration? config)
    {
        if (config is null) return (ConnectionConfiguration.Empty(false), "");
        config.Profile.Validate();
        return (config.Profile, Unprotect(config.ProtectedPassword));
    }
    public static Dictionary<string, UserConnection> LoadProfiles() => LoadProfilesFrom(DirectoryPath);
    internal static Dictionary<string, UserConnection> LoadProfilesFrom(string directory) => Read(directory)?.AllProfiles()
        .ToDictionary(entry => entry.Key, entry => new UserConnection(entry.Value.Profile, Unprotect(entry.Value.ProtectedPassword))) ?? [];

    private static string Protect(string password) => password.Length == 0 ? "" : Convert.ToBase64String(
        ProtectedData.Protect(Encoding.UTF8.GetBytes(password), null, DataProtectionScope.CurrentUser));

    public static void Save(CampusProfile profile, string password, UserConnection? backup = null, bool updateBackup = false)
        => SaveTo(DirectoryPath, profile, password, backup, updateBackup);

    internal static void SaveTo(string directory, CampusProfile profile, string password, UserConnection? backup = null, bool updateBackup = false)
    {
        profile.Validate();
        var protectedPassword = Protect(password);
        var config = (Read(directory) ?? new(profile, protectedPassword)).WithActive(profile, protectedPassword);
        if (updateBackup)
            config = config.WithBackupWifi(backup is null ? null : new(backup.Profile, Protect(backup.Password)));
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $"configuration-{Guid.NewGuid():N}.tmp");
        try {
            File.WriteAllText(temporary, JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temporary, Path.Combine(directory, "configuration.json"), true);
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
