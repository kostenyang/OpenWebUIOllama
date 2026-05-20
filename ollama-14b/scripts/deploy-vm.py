#!/usr/bin/env python3
# Deploy `ollama-14b` VM — sized for 14B Q4 models (Phi-4, Qwen2.5).
#
#   12 vCPU, 32 GB RAM, 200 GB disk (vs base 4/6/100)
#   IP 10.0.0.67, hostname ollama-14b
#
# Strategy: CloneVM_Task gets BOTH the customization spec AND a config-spec
# that bumps CPU/RAM and resizes the disk in the same vCenter task — no
# separate ReconfigVM step needed.  Disk grows from 100 → 200 GB at clone
# time; the guest OS still needs growpart + pvresize + lvextend + resize2fs
# on first boot (see scripts/resize-disk.sh).
#
#   pip3 install 'pyvmomi<8.0'    # Python 3.8 needs <8.0
#   python3 scripts/deploy-vm.py
import ssl, time, sys
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim

# vCenter
VC_HOST = '10.0.0.101'
VC_USER = 'administrator@vsphere.local'
VC_PASS = 'VMware1!'

# Inventory (home.lab specific)
TEMPLATE_MOID = 'vm-1183'         # ubuntu2004temp
FOLDER_MOID   = 'group-v1525'     # "Linux" folder
CLUSTER_MOID  = 'domain-c26'      # Cluster
DS_MOID       = 'datastore-45'    # pcssd2 (same as template; SSD3 ran out)

# VM spec
NEW_NAME    = 'ollama-14b'
NEW_IP      = '10.0.0.67'
NEW_MASK    = '255.255.254.0'
NEW_GW      = '10.0.0.1'
DNS_SERVERS = ['10.0.0.200', '10.0.0.1']
DOMAIN      = 'home.lab'

VCPU        = 12
MEM_MB      = 32 * 1024            # 32 GB
DISK_GB     = 200                  # 100 → 200 GB

def find(content, view_type, moid):
    cv = content.viewManager.CreateContainerView(content.rootFolder, [view_type], True)
    return next((o for o in cv.view if o._moId == moid), None)

def main():
    ctx = ssl._create_unverified_context()
    si = SmartConnect(host=VC_HOST, user=VC_USER, pwd=VC_PASS, sslContext=ctx)
    content = si.RetrieveContent()

    template = find(content, vim.VirtualMachine, TEMPLATE_MOID)
    folder   = find(content, vim.Folder, FOLDER_MOID)
    cluster  = find(content, vim.ClusterComputeResource, CLUSTER_MOID)
    ds       = find(content, vim.Datastore, DS_MOID)
    if not all([template, folder, cluster, ds]):
        print('Missing inventory object — check MOIDs.')
        sys.exit(1)

    # Customization spec
    custom = vim.vm.customization.Specification(
        identity=vim.vm.customization.LinuxPrep(
            hostName=vim.vm.customization.FixedName(name=NEW_NAME),
            domain=DOMAIN, timeZone='Asia/Taipei', hwClockUTC=True),
        globalIPSettings=vim.vm.customization.GlobalIPSettings(
            dnsSuffixList=[DOMAIN], dnsServerList=DNS_SERVERS),
        nicSettingMap=[vim.vm.customization.AdapterMapping(
            adapter=vim.vm.customization.IPSettings(
                ip=vim.vm.customization.FixedIp(ipAddress=NEW_IP),
                subnetMask=NEW_MASK, gateway=[NEW_GW]))],
        options=vim.vm.customization.LinuxOptions(),
    )

    # Grab the template's disk so we can resize it in-place.
    # IMPORTANT: keep the original `backing` object — passing a fresh
    # FlatVer2BackingInfo(fileName='') causes vCenter to replace the cloned
    # VMDK with a zero-size phantom (VM ends up unbootable, "incomplete
    # disks", and Destroy_Task refuses with InvalidVmState until you Reconfig
    # to detach the dead disk).  Only change capacityInKB; leave backing alone.
    disk = next(d for d in template.config.hardware.device
                if isinstance(d, vim.vm.device.VirtualDisk))
    disk.capacityInKB = DISK_GB * 1024 * 1024
    disk_spec = vim.vm.device.VirtualDeviceSpec(
        operation=vim.vm.device.VirtualDeviceSpec.Operation.edit,
        device=disk)

    config_spec = vim.vm.ConfigSpec(
        numCPUs=VCPU,
        numCoresPerSocket=VCPU,
        memoryMB=MEM_MB,
        deviceChange=[disk_spec],
    )

    spec = vim.vm.CloneSpec(
        location=vim.vm.RelocateSpec(datastore=ds, pool=cluster.resourcePool),
        template=False, powerOn=True,
        customization=custom, config=config_spec,
    )

    print(f'Cloning + reconfig: {VCPU} vCPU / {MEM_MB} MB RAM / {DISK_GB} GB disk')
    task = template.CloneVM_Task(folder=folder, name=NEW_NAME, spec=spec)
    while task.info.state in ('queued', 'running'):
        print(f'  progress: {task.info.progress}%')
        time.sleep(10)
    if task.info.state == 'error':
        print('ERROR:', task.info.error)
        sys.exit(2)
    res = task.info.result
    print(f'Deployed VM: {res.name} ({res._moId})')
    print(f'Wait ~2 min for customization → ssh root@{NEW_IP}')
    print('Then run: bash scripts/resize-disk.sh   (grows / to use full 200 GB)')
    Disconnect(si)

if __name__ == '__main__':
    main()
