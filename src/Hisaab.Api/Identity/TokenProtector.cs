using System.Security.Cryptography;
using System.Text;
using Hisaab.Domain;
namespace Hisaab.Api.Identity;

public sealed class TokenProtector(IConfiguration configuration)
{
    private byte[] Key() { try { var key = Convert.FromBase64String(configuration["Hisaab:EncryptionKey"] ?? ""); if (key.Length != 32) throw new FormatException(); return key; } catch (FormatException) { throw new DomainException(503, "encryption_unconfigured", "Secure account token storage is not configured."); } }
    public string Protect(string value) { var nonce = RandomNumberGenerator.GetBytes(12); var plain = Encoding.UTF8.GetBytes(value); var cipher = new byte[plain.Length]; var tag = new byte[16]; using var aes = new AesGcm(Key(), 16); aes.Encrypt(nonce, plain, cipher, tag); return Convert.ToBase64String(nonce.Concat(tag).Concat(cipher).ToArray()); }
    public string Unprotect(string value) { var bytes = Convert.FromBase64String(value); using var aes = new AesGcm(Key(), 16); var plain = new byte[bytes.Length - 28]; aes.Decrypt(bytes.AsSpan(0, 12), bytes.AsSpan(28), bytes.AsSpan(12, 16), plain); return Encoding.UTF8.GetString(plain); }
}
