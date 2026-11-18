using System.ClientModel.Primitives;
using System.Text.Json.Nodes;
using Azure.ResourceManager.Network;

namespace BastionReaper;

/// <summary>
/// A copy of a subnet without its NAT Gateway, to write back before the NAT Gateway is deleted. The SDK can't express
/// this: setting NatGatewayId to null still sends "natGateway": {}, which Azure rejects (MissingJsonReferenceId). So the
/// subnet goes through the SDK's own JSON, minus that property; every other link (network security group, delegations)
/// is kept as Azure returned it, since a subnet write replaces the whole subnet.
/// </summary>
public static class SubnetWithoutNatGateway
{
    public static SubnetData From(SubnetData subnet)
    {
        var json = JsonNode.Parse(ModelReaderWriter.Write(subnet).ToString())!;
        json["properties"]?.AsObject().Remove("natGateway");
        return ModelReaderWriter.Read<SubnetData>(BinaryData.FromString(json.ToJsonString()))!;
    }
}
