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

    public static (CampusProfile Profile, string Password) Load() => LoadFrom(DirectoryPath);
    internal static (CampusProfile Profile, string Password) LoadFrom(string directory)
    {
        var config = Read(directory);
        if (config is null) return (ConnectionConfiguration.Empty(false), "");
        config.Profile.Validate();
        return (config.Profile, Unprotect(config.ProtectedPassword));
    }
    public static Dictionary<string, UserConnection> LoadProfiles() => LoadProfilesFrom(DirectoryPath);
    internal static Dictionary<string, UserConnection> LoadProfilesFrom(string directory) => Read(directory)?.AllProfiles()
        .ToDictionary(entry => entry.Key, entry => new UserConnection(entry.Value.Profile, Unprotect(entry.Value.ProtectedPassword))) ?? [];

    public static void Save(CampusProfile profile, string password) => SaveTo(DirectoryPath, profile, password);
    internal static void SaveTo(string directory, CampusProfile profile, string password)
    {
        profile.Validate();
        var protectedPassword = string.IsNullOrEmpty(password) ? "" : Convert.ToBase64String(
            ProtectedData.Protect(Encoding.UTF8.GetBytes(password), null, DataProtectionScope.CurrentUser));
        var config = (Read(directory) ?? new(profile, protectedPassword)).WithActive(profile, protectedPassword);
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $"configuration-{Guid.NewGuid():N}.tmp");
        try {
            File.WriteAllText(temporary, JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temporary, Path.Combine(directory, "configuration.json"), true);
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
