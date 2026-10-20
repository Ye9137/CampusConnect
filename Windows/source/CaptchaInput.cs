namespace CampusConnect;

internal static class CaptchaInput
{
    internal static bool Allows(char value, bool numericOnly) =>
        numericOnly ? char.IsAsciiDigit(value) : char.IsAsciiLetterOrDigit(value);

    internal static bool IsValid(string code, int expectedLength, bool numericOnly) =>
        code.Length is > 0 and <= 12 && (expectedLength == 0 || code.Length == expectedLength) &&
        code.All(value => Allows(value, numericOnly));
}
