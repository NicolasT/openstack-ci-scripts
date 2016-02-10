
import io
import os
import re
import time

from fabric.api import env, execute, get, put, roles, run, parallel, sudo
from fabric.context_managers import cd, hide, prefix, settings
from fabric.contrib.files import exists, sed, upload_template


def abspath(path):
    """
    Get an absolute path relative to this script.
    """
    local_path, _ = os.path.split(__file__)
    return os.path.abspath(os.path.join(local_path, path))


def add_apt_repositories(credentials, release):
    """
    Add Scality APT repositories.

    :param credentials: credentials for packages.scality.com
    :type credentials: string
    :param release: RING release
    :type release: string
    """
    repository = (
        'http://{auth:s}@packages.scality.com/{release:s}/ubuntu'.format(
            auth=credentials,
            release=release,
        )
    )

    # Add GPG key.
    put(abspath('../scality5.gpg'), '/tmp')
    sudo('apt-key add /tmp/scality5.gpg')

    # Hide command execution, as well as any errors to not leak credentials.
    with settings(hide('running', 'aborts', 'warnings')):
        repo_cmd = sudo('apt-add-repository {0:s}'.format(repository),
                        warn_only=True)
        if repo_cmd.failed:
            raise Exception('Unable to add Scality repository')

    # Sagentd depends on snmp-mibs-downloader, which is in multiverse.
    sudo('apt-add-repository --enable-source multiverse')
    sudo('apt-get -q update')


def add_rpm_repositories(credentials, release, add_epel=True):
    """
    Add Scality Centos repositories.

    :param credentials: credentials for packages.scality.com
    :type credentials: string
    :param release: RING release
    :type release: string
    :param add_epel: whether to add the EPEL package repository
    :type add_epel: bool
    """
    pattern = re.compile(r'^CentOS.*release (?P<major>\d+)[.]')
    version_string = io.BytesIO()
    get('/etc/redhat-release', local_path=version_string)

    match = pattern.match(version_string.getvalue())
    if match is None:
        raise Exception('Unable to get CentOS version')

    version = int(match.group('major'))
    if version == 6:
        epel = (
            'http://mirror.cogentco.com/pub/linux/epel/6/i386/'
            'epel-release-6-8.noarch.rpm'
        )
    elif version == 7:
        epel = (
            'http://mirror.cogentco.com/pub/linux/epel/7/'
            'x86_64/e/epel-release-7-5.noarch.rpm'
        )
    else:
        raise Exception('Unsupported CentOS version {0:d}'.format(version))

    # Add epel repository.
    if add_epel:
        sudo('rpm -Uvh {0:s}'.format(epel))

    # Add scality repository.
    upload_template(
        filename=abspath('assets/etc/yum.repos.d/scality.repo'),
        destination='/etc/yum.repos.d',
        context={
            'credentials': credentials,
            'release': release,
            'centos_version': version,
        },
        use_sudo=True,
    )


def get_package_manager():
    """
    Detect OS package manager.

    :return: string
    """
    if run('which apt-get', warn_only=True).succeeded:
        return 'apt'
    elif run('which yum', warn_only=True).succeeded:
        return 'yum'

    raise Exception('Unable to detect package manager')


def install_packages(*args):
    """
    Use the OS specific package manager to install packages.

    :param args: variable argument list of package names to install
    :type args: argument list of strings
    """
    cmd = "{pkgman:s} install -y {packages:s}".format(
        pkgman=get_package_manager(),
        packages=" ".join(args),
    )
    sudo(cmd)


def relax_security():
    """
    Lower firewall and disable SELinux.

    Firewall and SELinux is (sometimes) configured by default on CentOS.
    """
    sudo('iptables -P INPUT ACCEPT')
    sudo('iptables -F INPUT')

    # If selinux happens to be deactivated already, it will exit non-zero
    sudo('setenforce 0', warn_only=True)


@roles('ring', 'nfs_connector', 'cifs_connector')
@parallel
def initial_host_config():
    """
    Initial OS tweaks required for proper setup.
    """
    if get_package_manager() == 'yum':
        relax_security()

        # Ensure that having a tty is not enforced by sudo.
        sed(
            filename='/etc/sudoers',
            before='Defaults.*requiretty',
            after='',
            use_sudo=True,
        )


@roles('ring', 'nfs_connector', 'cifs_connector')
@parallel
def add_package_repositories(credentials, release='stable_lorien'):
    """
    Add package repositories.

    :param credentials: credentials for packages.scality.com
    :type credentials: string
    :param release: RING release
    :type release: string
    """
    if get_package_manager() == 'apt':
        add_apt_repositories(credentials, release)
    else:
        add_rpm_repositories(credentials, release)


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
        '{ring:s} 1 {ring:s} 1'.format(name=name, devid=devid, ring=ring))

    retries = 10
    for retry in range(retries):
        time.sleep(5)
        cmd = run(
            'ringsh supv2 addVolumeConnector {name:s} {ip:s}:{port:d} '
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
        raise Exception('Unable to add connector to volume {0:s}'.format(name))


def setup_sfused(name, supervisor_host):
    """
    Install sfused and register it through sagentd to the supervisor.

    :param name: descriptive name of sfused role
    :type name: string
    :param supervisor_host: supervisor host for sagentd registration
    :type supervisor_host: string
    """
    install_packages('scality-sfused')
    sudo('/etc/init.d/scality-sfused start')

    upload_template(
        filename=abspath('assets/connector/etc/sagentd.yaml'),
        destination='/etc',
        context={'supervisor_host': supervisor_host},
        use_sudo=True,
    )

    manageconf_path = run('which sagentd-manageconf')  # Required for CentOS

    sudo(
        '{manageconf:s} -c /etc/sagentd.yaml add sfused-{role:s} '
        'type=sfused port=7002 address={host:s} '
        'path=/run/scality/connectors/sfused'.format(
            manageconf=manageconf_path,
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

    sfused = run('which sfused')  # Required for CentOS

    # There is a delay until the sfused config is pushed after volume creation.
    retries = 10
    for retry in range(retries):
        time.sleep(5)
        cmd = sudo(
            command='{0:s} -X -c /etc/sfused.conf'.format(sfused),
            warn_only=True,
        )
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
    if get_package_manager() == 'apt':
        install_packages('nfs-common')
    else:
        install_packages('nfs-utils')
        sudo('/etc/init.d/rpcbind start')

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

    install_packages('scality-cifs')
    conf_path = abspath('assets/connector/etc/samba/smb.conf')
    put(conf_path, '/etc/samba', use_sudo=True)
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
    install_packages('git', 'python-pip')
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

    install_packages('git')
    run('git clone https://github.com/scality/openstack-ci-scripts.git')

    # Hide aborts to not leak any repository passwords to console on failure.
    with cd('openstack-ci-scripts/jenkins'), prefix(export_cmd):
        with prefix('source ring-install.sh'), settings(hide('aborts')):
            run('install_base_scality_node', pty=False)  # avoid setup screen
            run('install_supervisor')
            run('install_ringsh')
            run('build_ring')


def setup_tunnel(name, local_ip, remote_ip, remote_net, gw_ip):
    """
    Setup one end of a tunnel to a remote network.

    :param name: tunnel link name
    :type name: string
    :param local_ip: ip of local end of tunnel
    :type local_ip: string
    :param remote_ip: ip of remote end of tunnel
    :type remote_ip: string
    :param remote_net: remote network routed over tunnel
    :type remote_net: string
    :param gw_ip: local gw to remote network
    :type gw_ip: string
    """
    sudo(
        'ip tunnel add {name:s} mode gre remote {remote:s} local '
        '{local:s} ttl 255'.format(
            name=name,
            remote=remote_ip,
            local=local_ip
        )
    )
    sudo('ip link set {name:s} up'.format(name=name))
    sudo('ip addr add {gw_ip:s}/24 dev {name:s}'.format(
            gw_ip=gw_ip,
            name=name,
        )
    )
    sudo('ip route add {remote_net:s} dev {name:s}'.format(
            remote_net=remote_net,
            name=name,
        )
    )
