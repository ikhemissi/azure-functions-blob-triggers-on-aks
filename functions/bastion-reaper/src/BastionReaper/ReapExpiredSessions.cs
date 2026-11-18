using Azure;
using Azure.ResourceManager;
using Azure.ResourceManager.Compute;
using Azure.ResourceManager.Network;
using Azure.ResourceManager.Network.Models;
using Azure.ResourceManager.Resources;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace BastionReaper;

/// <summary>
/// Every 15 minutes, ends the sessions whose time is up: deletes the resource group's Bastion hosts and NAT Gateways
/// that are due (SessionExpiry), then deallocates the jumpbox if it ended a session and DEALLOCATE_JUMPBOX is true.
/// It does what infra/scripts/bastion-down.sh does, for the sessions nobody ended.
/// </summary>
public class ReapExpiredSessions(ArmClient arm, IConfiguration settings, ILogger<ReapExpiredSessions> logger)
{
    [Function(nameof(ReapExpiredSessions))]
    public async Task Run([TimerTrigger("0 */15 * * * *")] TimerInfo timer, CancellationToken cancellationToken)
    {
        var resourceGroup = arm.GetResourceGroupResource(ResourceGroupResource.CreateResourceIdentifier(
            Required("SUBSCRIPTION_ID"), Required("RESOURCE_GROUP_NAME")));
        var now = DateTimeOffset.UtcNow;

        var bastionsDeleted = await DeleteDueBastionHosts(resourceGroup, now, cancellationToken);
        var natGatewaysDeleted = await DeleteDueNatGateways(resourceGroup, now, cancellationToken);
        logger.LogInformation("Deleted {Bastions} Bastion host(s) and {NatGateways} NAT Gateway(s)", bastionsDeleted, natGatewaysDeleted);

        if (bastionsDeleted > 0 && settings.GetValue("DEALLOCATE_JUMPBOX", defaultValue: true))
        {
            await DeallocateJumpbox(resourceGroup, cancellationToken);
        }
    }

    private async Task<int> DeleteDueBastionHosts(ResourceGroupResource resourceGroup, DateTimeOffset now, CancellationToken cancellationToken)
    {
        var deleted = 0;
        await foreach (var bastion in resourceGroup.GetBastionHosts().GetAllAsync(cancellationToken))
        {
            if (!IsDueAndNotDeleting(bastion.Data.Name, bastion.Data.Tags, bastion.Data.ProvisioningState, now))
            {
                continue;
            }

            // Waits for the end (about 8 minutes, measured), well within the 15 minutes between runs.
            await bastion.DeleteAsync(WaitUntil.Completed, cancellationToken);
            logger.LogInformation("Deleted the Bastion host {Name}", bastion.Data.Name);
            deleted++;
        }
        return deleted;
    }

    private async Task<int> DeleteDueNatGateways(ResourceGroupResource resourceGroup, DateTimeOffset now, CancellationToken cancellationToken)
    {
        var deleted = 0;
        await foreach (var natGateway in resourceGroup.GetNatGateways().GetAllAsync(cancellationToken))
        {
            if (!IsDueAndNotDeleting(natGateway.Data.Name, natGateway.Data.Tags, natGateway.Data.ProvisioningState, now))
            {
                continue;
            }

            // A NAT Gateway still attached to a subnet can't be deleted.
            foreach (var subnetReference in natGateway.Data.Subnets)
            {
                SubnetResource subnet = await arm.GetSubnetResource(subnetReference.Id).GetAsync(cancellationToken: cancellationToken);
                await subnet.UpdateAsync(WaitUntil.Completed, SubnetWithoutNatGateway.From(subnet.Data), cancellationToken);
                logger.LogInformation("Detached the NAT Gateway {Name} from the subnet {Subnet}", natGateway.Data.Name, subnet.Data.Name);
            }

            await natGateway.DeleteAsync(WaitUntil.Completed, cancellationToken);
            logger.LogInformation("Deleted the NAT Gateway {Name}", natGateway.Data.Name);
            deleted++;
        }
        return deleted;
    }

    private async Task DeallocateJumpbox(ResourceGroupResource resourceGroup, CancellationToken cancellationToken)
    {
        var jumpboxName = Required("JUMPBOX_NAME");
        VirtualMachineResource jumpbox = await resourceGroup.GetVirtualMachineAsync(jumpboxName, cancellationToken: cancellationToken);
        await jumpbox.DeallocateAsync(WaitUntil.Completed, cancellationToken: cancellationToken);
        logger.LogInformation("Deallocated the jumpbox {Name}", jumpboxName);
    }

    private bool IsDueAndNotDeleting(string name, IDictionary<string, string> tags, NetworkProvisioningState? state, DateTimeOffset now)
    {
        var due = SessionExpiry.IsDue(tags, now, out var reason);
        logger.LogInformation("{Name}: {Reason}, {Verdict} (state {State})", name, reason, due ? "due" : "kept", state);
        return due && state != NetworkProvisioningState.Deleting;
    }

    private string Required(string name) =>
        settings[name] ?? throw new InvalidOperationException($"The app setting {name} is missing.");
}
