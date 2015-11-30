import datetime
import fabric
import io
import json
import os
import time

import heatclient.client
import keystoneclient.auth.identity.v2
import keystoneclient.session

from fabric.api import env, execute, task, put, roles, run, parallel, sudo
from fabric.context_managers import cd, hide, prefix, settings, shell_env
from fabric.contrib.files import append, contains, sed, upload_template
from heatclient.common import template_utils


@roles('nfs_connector', 'cifs_connector')
@parallel
def add_apt_repositories(credentials):
    """
    Add Scality APT repositories.

    :param credentials: credentials for packages.scality.com
    :type credentials: string
    """
    release = 'stable_lorien'
    gpg_key = '4A23AD0E'
    repository = (
        'http://{auth:s}@packages.scality.com/{release:s}/ubuntu'.format(
            auth=credentials,
            release=release,
        )
    )

    # Add GPG key.
    sudo('gpg --keyserver pool.sks-keyservers.net --recv-keys %s' % gpg_key)
    sudo('gpg -a --export 4A23AD0E | apt-key add -')

    # Hide command execution, as well as any errors to not leak credentials
    with settings(hide('running', 'aborts', 'warnings')):
        repo_cmd = sudo('apt-add-repository {0:s}'.format(repository),
                        warn_only=True)
        if repo_cmd.failed:
            raise Exception("Unable to add Scality repository")

    # Sagentd depends on snmp-mibs-downloader, which is in multiverse.
    sudo('apt-add-repository --enable-source multiverse')
    sudo('apt-get -q update')


def register_sagentd(instance_name, ip, port=7084):
    """
    Register an sagentd instance at the supervisor.

    :param instance_name: descriptive name of the sagentd node
    :type instance_name: string
    :param ip: ip of the sagent node for registration
    :type ip: string
    :param port: port of the sagent node for registration
    :type port: int
    """
    run('ringsh supervisor serverAdd {name:s}-sa '
        '{ip:s} {port:d}'.format(name=instance_name, ip=ip, port=port))


def create_volume(name, role, devid, connector_ip, connector_port=7002,
                  ring="MyRing"):
    """
    Create a volume and associate a connector.

    :param name: volume name
    :type name: string
    :param role: the role to associate with the connector exposing the volume
        (nfs or cifs)
    :type role: string
    :param devid: device id for the volume
    :type devid: int
    :param connector_ip: ip of the connector exposing the volume
    :type connector_ip: string
    :param connector_port: port of the connector exposing the volume
    :type connector_port: int
    :param ring: name of the ring backing the volume (data and metadata)
    :type ring: string
    """
    run('ringsh supervisor addVolume {name:s} sofs {devid:d} '
        '{ring:s} 1 {ring:s} 1'.format(
            name=name,
            devid=devid,
            ring=ring,
        )
    )

    retries = 10
    for retry in range(retries):
        time.sleep(5)
        cmd = run('ringsh supv2 addVolumeConnector {name:s} {ip:s}:{port:d} '
            '{role:s}'.format(
            name=name,
            ip=connector_ip,
            port=connector_port,
            role=role,
            ),
            warn_only=True,
        )
        if cmd.succeeded:
            break
    else:
        raise Exception("Unable to add connector to volume '%s'".format(name))


def setup_sfused(name, supervisor_host):
    """
    Install sfused and register it through sagentd to the supervisor.

    :param name: descriptive name of sfused role
    :type name: string
    :param supervisor_host: supervisor host for sagentd registration
    :type supervisor_host: string
    """
    sudo('apt-get -q -y install scality-sfused')

    upload_template(
        filename='assets/connector/etc/sagentd.yaml',
        destination='/etc',
        context={'supervisor_host': supervisor_host},
        use_sudo=True,
    )

    sudo('sagentd-manageconf -c /etc/sagentd.yaml add sfused-{role:s} '
        'type=sfused port=7002 address={host:s} '
        'path=/run/scality/connectors/sfused'.format(
            role=name,
            host=env.host,
        )
    )
    sudo('/etc/init.d/scality-sagentd restart')

    execute(register_sagentd, name, env.host, host=supervisor_host)


def setup_connector(role, volume_name, devid, supervisor_host):
    """
    Deploy an sfused connector, and an associated volume.

    :param role: connector role (nfs or cifs)
    :type role: string
    :param volume_name: the name of the SOFS volume to create and expose
    :type volume_name: string
    :param devid: device id to associate with the volume
    :type devid: int
    :param supervisor_host: hostname or ip of the supervisor for registration
        of connector and volume
    :type supervisor_host: string
    """
    setup_sfused(role, supervisor_host)

    execute(create_volume, volume_name, role, devid, env.host,
            host=supervisor_host)

    # There is a delay until the sfused config is pushed after volume creation.
    retries = 10
    for retry in range(retries):
        time.sleep(5)
        cmd = sudo('sfused -X -c /etc/sfused.conf', warn_only=True)
        if cmd.succeeded:
            break
    else:
        raise Exception("Catalog init failed for '{0:s}'".format(volume_name))
    sudo('/etc/init.d/scality-sfused restart')


@roles('nfs_connector')
def setup_nfs_connector(volume_name, devid, supervisor_host):
    """
    Deploy an sfused nfs connector and SOFS accompanying volume.

    :param volume_name: the name of the SOFS volume to create and
        expose over nfs
    :type volume_name: string
    :param devid: device id to associate with the volume
    :type devid: int
    :param supervisor_host: hostname or ip of the supervisor for registration
        of connector and volume
    :type supervisor_host: string
    """
    sudo('apt-get -q -y install nfs-common')
    setup_connector('nfs', volume_name, devid, supervisor_host)
    put('assets/connector/etc/exports.conf', '/etc/', use_sudo=True)
    sudo('/etc/init.d/scality-sfused restart')


@roles('cifs_connector')
def setup_cifs_connector(volume_name, devid, supervisor_host):
    """
    Deploy an sfused cifs connector and SOFS accompanying volume.

    :param volume_name: the name of the SOFS volume to create and
        expose over cifs
    :type volume_name: string
    :param devid: device id to associate with the volume
    :type devid: int
    :param supervisor_host: hostname or ip of the supervisor for registration
        of connector and volume
    :type supervisor_host: string
    """
    setup_connector('cifs', volume_name, devid, supervisor_host)

    sudo('apt-get -q -y install scality-cifs')
    put('assets/connector/etc/samba/smb.conf', '/etc/samba', use_sudo=True)
    sed(
        filename='/etc/default/sernet-samba',
        before='SAMBA_START_MODE="none"',
        after='SAMBA_START_MODE="classic"',
        use_sudo=True,
    )

    sudo('mkdir -p /var/run/samba')
    sudo('testparm -s')

    # The sernet-samba-smbd init script is flaky: if the parent exits
    # to quickly, the smbd process does not have time to daemonize.
    sudo('/etc/init.d/sernet-samba-smbd start && sleep 5')


@roles('nfs_connector', 'cifs_connector')
@parallel
def install_scality_manila_utils():
    """
    Install the scality-manila-utils python package.
    """
    sudo('apt-get -q -y install git-core python-pip')
    sudo('pip install git+https://github.com/scality/scality-manila-utils.git')


@roles('ring')
def setup_ring():
    """
    Bootstrap Scality RING (environment variable `SCAL_PASS` must be exported).

    The environment variable `SCAL_PASS` is expected to hold username:password
    for fetching scality packages.
    """
    install_env = {
        'SUP_ADMIN_LOGIN': 'supadmin',
        'SUP_ADMIN_PASS': 'supadmin',
        'INTERNAL_MGMT_LOGIN': 'admin',
        'INTERNAL_MGMT_PASS': 'admin',
        'HOST_IP': env.host,
        'SCAL_PASS': os.environ['SCAL_PASS'],
        'AllowEncodedSlashes': 'NoDecode',
    }
    export_vars = ('{0:s}={1:s}'.format(k, v) for k, v in install_env.items())
    export_cmd = 'export {0:s}'.format(' '.join(export_vars))

    sudo('apt-get -q update')
    sudo('apt-get -q -y install git-core')
    run('git clone https://github.com/scality/openstack-ci-scripts.git')

    # Hide aborts to not leak any repository passwords to console on failure.
    with cd('openstack-ci-scripts/jenkins'), prefix(export_cmd):
        with prefix('source ring-install.sh'), settings(hide('aborts')):
            run('add_source')
            run('install_base_scality_node', pty=False)  # avoid setup screen
            run('install_supervisor')
            run('install_ringsh')
            run('build_ring')


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


def deploy_infrastructure(public_key):
    """
    Deploy infrastructure backing ring and connectors.

    Three hosts will be deployed:
     - ring: for the purpose of hosting a single node ring and supervisor
     - nfs_connector: for the purpose of running sfused + nfs
     - cifs_connector: for the purpose of running sfused + samba

    :param public_key: public key for infrastructure authentication
    :type public_key: string
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
def deploy(public_key):
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
    """
    hosts = deploy_infrastructure(public_key)
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

    execute(add_apt_repositories, os.environ['SCAL_PASS'])
    execute(setup_ring)

    execute(setup_nfs_connector, 'manila_nfs', 1, hosts['ring_ip'])
    execute(setup_cifs_connector, 'manila_cifs', 2, hosts['ring_ip'])

    execute(install_scality_manila_utils)


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
