using Hisaab.Domain;
namespace Hisaab.Api.Contracts;

public sealed record CreateGroupRequest(string Name, GroupType Type);
