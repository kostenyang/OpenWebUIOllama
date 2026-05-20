#!/usr/bin/env python3
# Deploy `ollama` VM from `ubuntu2004temp` template using customization spec
# so that the new VM boots with the right hostname / static IP and there's no
# IP conflict with the cloned-from machine.
#
# Run on any box with `pyvmomi<8.0` (Python 3.8 OK) installed:
#     pip3 install 'pyvmomi<8.0'
#     python3 scripts/deploy-vm.py
#
# All vCenter / VM identifiers are hard-coded for the home.lab environment.
# Adjust VC_*, TEMPLATE_MOID, FOLDER_MOID, CLUSTER_MOID, DS_MOID for your env.
import ssl, time, sys
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim

VC_HOST = '10.0.0.101'
VC_USER = 'administrator@vsphere.local'
VC_PASS = 'VMware1!'

TEMPLATE_MOID = 'vm-1183'        # ubuntu2004temp
FOLDER_MOID   = 'group-v1525'    # "Linux" folder
CLUSTER_MOID  = 'domain-c26'     # Cluster
DS_MOID       = 'datastore-14801'  # SSD3

NEW_NAME    = 'ollama'
NEW_IP      = '10.0.0.63'
NEW_MASK    = '255.255.254.0'
NEW_GW      = '10.0.0.1'
DNS_SERVERS = ['10.0.0.200', '10.0.0.1']
DOMAIN      = 'home.lab'

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
    print(f'template={template.name} folder={folder.name} cluster={cluster.name} ds={ds.name}')

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

    spec = vim.vm.CloneSpec(
        location=vim.vm.RelocateSpec(datastore=ds, pool=cluster.resourcePool),
        template=False, powerOn=True, customization=custom,
    )

    print('Cloning from template...')
    task = template.CloneVM_Task(folder=folder, name=NEW_NAME, spec=spec)
    while task.info.state in ('queued', 'running'):
        print(f'  progress: {task.info.progress}%')
        time.sleep(10)
    state = task.info.state
    if state == 'error':
        print('ERROR:', task.info.error)
        sys.exit(2)
    res = task.info.result
    print(f'Deployed VM: {res.name} ({res._moId})')
    print(f'Wait ~2 min for customization to apply, then: ssh root@{NEW_IP}')
    Disconnect(si)

if __name__ == '__main__':
    main()
