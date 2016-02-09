import datetime
import io
import json
import os
import time

import bootstrap

import heatclient.client
import keystoneclient.auth.identity.v2
import keystoneclient.session

from fabric.api import env, execute, task
from heatclient.common import template_utils


def heat_client_session():
    """
    Setup a keystone authenticated heat client session.

    The following environment variables must be set:
     - OS_AUTH_URL
     - OS_TENANT_NAME
     - OS_USERNAME
     - OS_PASSWORD

    :return: :py:class:`heatclient.client.Client`
    """
    auth = keystoneclient.auth.identity.v2.Password(
        auth_url=os.environ['OS_AUTH_URL'],
        tenant_name=os.environ['OS_TENANT_NAME'],
        username=os.environ['OS_USERNAME'],
        password=os.environ['OS_PASSWORD'],
    )

    keystone_session = keystoneclient.session.Session(auth=auth)
    heat_endpoint = keystone_session.get_endpoint(
        service_type='orchestration',
        interface='publicURL',
    )

    return heatclient.client.Client(
        version=1,
        endpoint=heat_endpoint,
        session=keystone_session,
    )


def deploy_infrastructure(public_key, image):
    """
    Deploy infrastructure backing ring and connectors.

    Three hosts will be deployed:
     - ring: for the purpose of hosting a single node ring and supervisor
     - nfs_connector: for the purpose of running sfused + nfs
     - cifs_connector: for the purpose of running sfused + samba

    :param public_key: public key for infrastructure authentication
    :type public_key: string
    :param image: glance image to boot from
    :type image: string
    """
    heat_client = heat_client_session()
    template_file = 'manila-ci.yaml'
    timestamp = datetime.datetime.now().strftime('%Y-%m-%d_%H%M%S')
    deployment_name='ManilaCI_{0:s}'.format(timestamp)
    tpl_files, template = template_utils.get_template_contents(template_file)
    api_response = heat_client.stacks.create(
        stack_name=deployment_name,
        template=template,
        files=tpl_files,
        parameters={
            'public_key': public_key,
            'deployment_name': deployment_name,
            'image': image,
        },
    )

    # Record deployment stack id.
    stack_id = api_response['stack']['id']
    print('Initiated Manila CI deployment: {0:s}'.format(stack_id))
    with io.open('/tmp/manilaci-deployment', 'wb') as f:
        json.dump({'stack_id': stack_id}, f, indent=2)

    # Wait for deployment to complete.
    retries = 60
    for retry in range(retries):
        time.sleep(5)
        stack = heat_client.stacks.get(stack_id)
        if stack.status == 'COMPLETE':
            break
    else:
        raise Exception(
            "Deployment of infrastructure failed. "
            "Stack id: '{0:s}' / {1:s}".format(stack_id, stack.status)
        )

    hosts = {}
    for out in stack.outputs:
        hosts[out['output_key']] = out['output_value']

    for host in ('ring_ip', 'nfs_ip', 'cifs_ip'):
        if host not in hosts:
            raise Exception("Expected '{0:s}' in deployment".format(host))

    return hosts


@task
def deploy(public_key, image="Ubuntu 14.04 amd64"):
    """
    Deploy a single node ring with nfs and cifs connector.

    Setup the infrastructure and configure required packages for integration
    with the Scality Manila Driver.

    The following environment variables must be set:
     - OS_AUTH_URL
     - OS_TENANT_NAME
     - OS_USERNAME
     - OS_PASSWORD

    :param public_key: public key for infrastructure authentication
    :type public_key: string
    :param image: glance image to boot from
    :type image: string
    """
    hosts = deploy_infrastructure(public_key, image)
    env.roledefs = {
        'ring': [hosts['ring_ip']],
        'nfs_connector': [hosts['nfs_ip']],
        'cifs_connector': [hosts['cifs_ip']],
    }

    # Write instance IPs to file.
    # The scality-manila-devstack-plugin relies on this information.
    infra_dumpfile = '/tmp/manilaci-hosts'
    export_lines = u'''
        export NFS_CONNECTOR_HOST={nfs_ip:s}
        export CIFS_CONNECTOR_HOST={cifs_ip:s}
        export RING_HOST={ring_ip:s}
    '''.format(**hosts)

    with io.open(infra_dumpfile, 'w') as f:
        f.write(export_lines)

    print('Wrote infrastructure to {filename:s}: {lines:s}'.format(
        filename=infra_dumpfile,
        lines=export_lines
        )
    )

    execute(bootstrap.initial_host_config)
    execute(bootstrap.add_package_repositories, os.environ['SCAL_PASS'])
    execute(bootstrap.setup_ring)

    execute(bootstrap.setup_nfs_connector, 'manila_nfs', 1, hosts['ring_ip'])
    execute(bootstrap.setup_cifs_connector, 'manila_cifs', 2, hosts['ring_ip'])

    execute(bootstrap.install_scality_manila_utils)


@task
def configure_network_path(local_ip, nfs_ip, cifs_ip):
    """
    Configure network path to the CIFS and NFS connector for tenant use.

    The following environment variables must be set:
     - TENANTS_NET
     - TENANT_NFS_GW
     - TENANT_SMB_GW
     - RINGNET_NFS_EXPORT_IP
     - RINGNET_SMB_EXPORT_IP
     - RINGNET_NFS
     - RINGNET_SMB

    :param local_ip: ip of local end of tunnel
    :type local_ip: string
    :param nfs_ip: nfs connector ip
    :type nfs_ip: string
    :param cifs_ip: cifs connector ip
    :type cifs_ip: string
    """
    nfs_net = os.environ['RINGNET_NFS']
    nfs_gw = os.environ['TENANT_NFS_GW']
    nfs_export_ip = os.environ['RINGNET_NFS_EXPORT_IP']
    cifs_net = os.environ['RINGNET_SMB']
    cifs_gw = os.environ['TENANT_SMB_GW']
    cifs_export_ip = os.environ['RINGNET_SMB_EXPORT_IP']
    tenants_net = os.environ['TENANTS_NET']

    # Setup tunnel to NFS connector.
    execute(
        bootstrap.setup_tunnel,
        'nfs',
        local_ip,
        nfs_ip,
        nfs_net,
        nfs_gw,
        host=local_ip,
    )
    execute(
        bootstrap.setup_tunnel,
        'nfs',
        nfs_ip,
        local_ip,
        tenants_net,
        nfs_export_ip,
        host=nfs_ip,
    )

    # Setup tunnel to CIFS connector.
    execute(
        bootstrap.setup_tunnel,
        'cifs',
        local_ip,
        cifs_ip,
        cifs_net,
        cifs_gw,
        host=local_ip,
    )
    execute(
        bootstrap.setup_tunnel,
        'cifs',
        cifs_ip,
        local_ip,
        tenants_net,
        cifs_export_ip,
        host=cifs_ip,
    )


@task
def destroy(stack_id=None):
    """
    Tear down a deployment.

    The following environment variables must be set:
     - OS_AUTH_URL
     - OS_TENANT_NAME
     - OS_USERNAME
     - OS_PASSWORD

    :param stack_id: the stack id of the deployment to remove (optional)
        if it is not given, it is assumed to be found under
        /tmp/manilaci-deployment
    :type stack_id: string
    """
    if stack_id is None:
        with io.open('/tmp/manilaci-deployment', 'rb') as f:
            deployment = json.load(f)
            stack_id = deployment['stack_id']

    heat_client_session().stacks.delete(stack_id)
