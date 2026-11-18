using System.ClientModel.Primitives;
using Azure.Core;
using Azure.ResourceManager.Network;

namespace BastionReaper.Tests;

public class SubnetWithoutNatGatewayTests
{
    private const string Group = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg";

    private static SubnetData JumpboxSubnet() => new()
    {
        Name = "jumpbox",
        AddressPrefix = "10.40.1.0/27",
        NatGatewayId = new ResourceIdentifier($"{Group}/providers/Microsoft.Network/natGateways/ng"),
        NetworkSecurityGroup = new NetworkSecurityGroupData { Id = new ResourceIdentifier($"{Group}/providers/Microsoft.Network/networkSecurityGroups/nsg") },
    };

    private static string RequestBody(SubnetData subnet) => ModelReaderWriter.Write(subnet).ToString();

    [Fact]
    public void Clearing_the_id_alone_still_sends_an_empty_reference()
    {
        var subnet = JumpboxSubnet();
        subnet.NatGatewayId = null;

        Assert.Contains("\"natGateway\":{}", RequestBody(subnet));
    }

    [Fact]
    public void The_copy_has_no_NAT_Gateway_and_keeps_the_rest()
    {
        var body = RequestBody(SubnetWithoutNatGateway.From(JumpboxSubnet()));

        Assert.DoesNotContain("natGateway", body);
        Assert.Contains("networkSecurityGroups/nsg", body);
        Assert.Contains("10.40.1.0/27", body);
    }
}
