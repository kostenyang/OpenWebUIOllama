#!/usr/bin/env python3
# Deploy an mcp-server VM (vcf-mcp host).
#
# Specs by default (4 vCPU / 8 GB RAM / 100 GB disk):
#   the FastMCP SSE server itself is tiny; the bump from 4 GB (template)
#   to 8 GB is just headroom for ad-hoc Python scripts you may run on
#   the same box (pyvmomi inventory walks, debugging, etc.).
#
# Override via CLI args if you want a different IP / name / specs:
#   python3 deploy-mcp-vm.py [--name N] [--ip I] [--cpu C] [--mem-mb M] [--disk-gb D]
import argparse, ssl, sys, time
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim

VC_HOST = '10.0.0.101'
VC_USER = 'administrator@vsphere.local'
VC_PASS = 'VMware1!'

TEMPLATE_MOID = 'vm-1183'         # ubuntu2004temp
FOLDER_MOID   = 'group-v1525'     # Linux folder
CLUSTER_MOID  = 'domain-c26'      # Cluster
import os
DS_MOID       = os.environ.get('DS_MOID', 'datastore-45')  # default pcssd2; override DS_MOID=datastore-XX

DEFAULTS = dict(
    name    = 'mcp-test',         # don't overwrite the live mcp-server by default
    ip      = '10.0.0.68',
    mask    = '255.255.254.0',
    gw      = '10.0.0.1',
    cpu     = 4,
    mem_mb  = 8 * 1024,
    disk_gb = 100,
    dns     = ['10.0.0.200', '10.0.0.1'],
    domain  = 'home.lab',
)

def parse():
    p = argparse.ArgumentParser()
    p.add_argument('--name',    default=DEFAULTS['name'])
    p.add_argument('--ip',      default=DEFAULTS['ip'])
    p.add_argument('--mask',    default=DEFAULTS['mask'])
    p.add_argument('--gw',      default=DEFAULTS['gw'])
    p.add_argument('--cpu',     type=int, default=DEFAULTS['cpu'])
    p.add_argument('--mem-mb',  type=int, default=DEFAULTS['mem_mb'])
    p.add_argument('--disk-gb', type=int, default=DEFAULTS['disk_gb'])
    return p.parse_args()

def find(content, view_type, moid):
    cv = content.viewManager.CreateContainerView(content.rootFolder, [view_type], True)
    return next((o for o in cv.view if o._moId == moid), None)

def main():
    a = parse()
    ctx = ssl._create_unverified_context()
    si = SmartConnect(host=VC_HOST, user=VC_USER, pwd=VC_PASS, sslContext=ctx)
    content = si.RetrieveContent()

    template = find(content, vim.VirtualMachine, TEMPLATE_MOID)
    folder   = find(content, vim.Folder, FOLDER_MOID)
    cluster  = find(content, vim.ClusterComputeResource, CLUSTER_MOID)
    ds       = find(content, vim.Datastore, DS_MOID)
    if not all([template, folder, cluster, ds]):
        print('Missing inventory object — check MOIDs.'); sys.exit(1)

    custom = vim.vm.customization.Specification(
        identity=vim.vm.customization.LinuxPrep(
            hostName=vim.vm.customization.FixedName(name=a.name),
            domain=DEFAULTS['domain'], timeZone='Asia/Taipei', hwClockUTC=True),
        globalIPSettings=vim.vm.customization.GlobalIPSettings(
            dnsSuffixList=[DEFAULTS['domain']], dnsServerList=DEFAULTS['dns']),
        nicSettingMap=[vim.vm.customization.AdapterMapping(
            adapter=vim.vm.customization.IPSettings(
                ip=vim.vm.customization.FixedIp(ipAddress=a.ip),
                subnetMask=a.mask, gateway=[a.gw]))],
        options=vim.vm.customization.LinuxOptions(),
    )

    disk = next(d for d in template.config.hardware.device
                if isinstance(d, vim.vm.device.VirtualDisk))
    # If user asked for a different size than the template, edit-in-place.
    # IMPORTANT: keep the cloned disk's backing intact (see ollama-14b/scripts/deploy-vm.py
    # for the gory details of why passing a fresh backing kills the VMDK).
    config_spec = vim.vm.ConfigSpec(numCPUs=a.cpu, numCoresPerSocket=a.cpu, memoryMB=a.mem_mb)
    if a.disk_gb * 1024 * 1024 != disk.capacityInKB:
        disk.capacityInKB = a.disk_gb * 1024 * 1024
        config_spec.deviceChange = [vim.vm.device.VirtualDeviceSpec(
            operation=vim.vm.device.VirtualDeviceSpec.Operation.edit, device=disk)]

    spec = vim.vm.CloneSpec(
        location=vim.vm.RelocateSpec(datastore=ds, pool=cluster.resourcePool),
        template=False, powerOn=True,
        customization=custom, config=config_spec,
    )

    print(f'Cloning {a.name} ({a.cpu} vCPU / {a.mem_mb} MB RAM / {a.disk_gb} GB disk → {a.ip})')
    task = template.CloneVM_Task(folder=folder, name=a.name, spec=spec)
    while task.info.state in ('queued', 'running'):
        print(f'  progress: {task.info.progress}%'); time.sleep(10)
    if task.info.state == 'error':
        print('ERROR:', task.info.error); sys.exit(2)
    res = task.info.result
    print(f'Deployed: {res.name} ({res._moId})')
    print(f'Wait ~2 min for customization → ssh root@{a.ip}')
    Disconnect(si)

if __name__ == '__main__':
    main()
