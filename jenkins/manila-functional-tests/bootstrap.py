
import io
import json
import os
import re
import time
import yaml

from fabric.api import env, execute, get, put, run, sudo
from fabric.context_managers import hide, settings, shell_env
from fabric.contrib.files import append, sed, upload_template

CREDENTIALS = {
    'supuser': 'supadmin',
    'suppass': 'suppass',
    'mgmtuser': 'superUser',
    'mgmtpass': 'adminPass',
}


def memoize(f):
    """
    Decorator providing results caching.

    This is a rather naive approach which relies on the string representation
    of the arguments.  If a type of an argument does not implement `repr`,
    caching of calls will be guaranteed.
    """
    f.memoized_result = {}

    def wrapper(*args, **kwargs):
        cache_key = repr(args) + repr(kwargs)
        if cache_key not in f.memoized_result:
            f.memoized_result[cache_key] = f(*args, **kwargs)
        return f.memoized_result[cache_key]

    return wrapper


def update_yaml(path, predicate, update, use_sudo=False):
    """
    Load configuration from path and apply update.

    A yaml document at `path` is deserialized, and updated with the given
    `update` function if `predicate` holds.

    :param path: path to yaml document
    :type path: string
    :param predicate: function taking a python representation of the yaml
        document, and returns either `True` or `False`
    :type predicate: function
    :param update: function taking a python representation of the yaml
        document, and does in-place update
    """
    doc_in = io.BytesIO()
    get(path, local_path=doc_in, use_sudo=use_sudo)
    doc_in.seek(0)
    doc = yaml.safe_load(doc_in)
    if predicate(doc):
        update(doc)
        doc_out = io.BytesIO()
        yaml.safe_dump(doc, stream=doc_out)
        doc_out.seek(0)
        put(doc_out, path, use_sudo=use_sudo)


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
        "'deb [arch=amd64] "
        "http://{auth:s}@packages.scality.com/{release:s}/ubuntu "
        "trusty main'".format(
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


@memoize
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


@memoize
def has_systemd():
    systemd = run('which systemctl', warn_only=True)
    return systemd.succeeded


def start_service(name):
    """
    Start a system service.

    :param name: name of service to start
    :type name: string
    """
    if has_systemd():
        sudo('systemctl start {0:s}'.format(name))
    else:
        sudo('/etc/init.d/{0:s} start'.format(name))


def restart_service(name):
    """
    Restart a system service.

    :param name: name of service to restart
    :type name: string
    """
    if has_systemd():
        sudo('systemctl restart {0:s}'.format(name))
    else:
        sudo('/etc/init.d/{0:s} restart'.format(name))


def relax_security():
    """
    Lower firewall and disable SELinux.

    Firewall and SELinux is (sometimes) configured by default on CentOS.
    """
    sudo('iptables -P INPUT ACCEPT')
    sudo('iptables -F INPUT')

    # If selinux happens to be deactivated already, it will exit non-zero
    sudo('setenforce 0', warn_only=True)


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

    # Sudo is noisy if it can't resolve local hostname.
    hostname = run('hostname')
    ping = run('ping {0:s}'.format(hostname), warn_only=True)
    if not ping.succeeded:
        append('/etc/hosts', '127.0.1.1 {0:s}'.format(hostname), use_sudo=True)


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
    server_listing = run('ringsh supervisor serverList')
    if ip not in server_listing:
        run('ringsh supervisor serverAdd {name:s}-sa '
            '{ip:s} {port:d}'.format(name=instance_name, ip=ip, port=port))


def create_volume(name, role, devid, connector_ip, connector_port=7002,
                  data_ring="MyRing", md_ring='MyRing'):
    """
    Create a volume and associate a connector.

    :param name: volume name
    :type name: string
    :param role: the role to associate with the connector exposing the volume
        (nfs, cifs or localfs)
    :type role: string
    :param devid: device id for the volume
    :type devid: int
    :param connector_ip: ip of the connector exposing the volume
    :type connector_ip: string
    :param connector_port: port of the connector exposing the volume
    :type connector_port: int
    :param data_ring: name of the ring backing the volume data
    :type data_ring: string
    :param md_ring: name of the ring backing the volume metadata
    :type md_ring: string
    """
    run('ringsh supervisor addVolume {name:s} sofs {devid:d} {data_ring:s} 1 '
        '{md_ring:s} 1'.format(name=name, devid=devid, data_ring=data_ring,
                               md_ring=md_ring))

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
    start_service('scality-sfused')

    # Ensure supervisor is whitelisted
    update_yaml(
        path='/etc/sagentd.yaml',
        predicate=lambda conf: supervisor_host not in conf['ip_whitelist'],
        update=lambda conf: conf['ip_whitelist'].append(supervisor_host),
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

    restart_service('scality-sagentd')
    execute(register_sagentd, name, env.host, host=supervisor_host)


def setup_connector(role, volume_name, devid, supervisor_host,
                    data_ring='MyRing', md_ring='MyRing', name=None):
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
    :param data_ring: name of the ring backing the volume data
    :type data_ring: string
    :param md_ring: name of the ring backing the volume metadata
    :type md_ring: string
    :param name: name of connector, defaults to role, eg nfs
    :type name: string
    """
    connector_name = name or role
    setup_sfused(connector_name, supervisor_host)

    execute(create_volume, volume_name, role, devid, env.host,
            data_ring=data_ring, md_ring=md_ring, host=supervisor_host)

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

    restart_service('scality-sfused')


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
        start_service('rpcbind')

    setup_connector('nfs', volume_name, devid, supervisor_host)
    put('assets/connector/etc/exports.conf', '/etc/', use_sudo=True)
    restart_service('scality-sfused')


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


def put_installation_credentials():
    """
    Put the credentials required for installation of supervisor and node.
    """
    upload_template(
        filename=abspath('assets/scality-installer-credentials'),
        destination='/tmp',
        context=CREDENTIALS,
    )


def setup_ringsh(ring, supervisor_host, node_host=None):
    """
    Install and configure ringsh.

    :param ring: ring name (dso name)
    :type ring: string
    :param supervisor_host: hostname or ip of the supervisor
    :type supervisor_host: string
    """
    if node_host is not None:
        node_section = {
            'address': node_host,
            'chordPort': 4244,
            'adminPort': '6444',
            'dsoName': ring,
        }
    else:
        node_section = 'None'

    install_packages('scality-ringsh')
    upload_template(
        filename=abspath('assets/config.py'),
        destination='/usr/local/scality-ringsh/ringsh',
        context={
            'mgmtuser': CREDENTIALS['mgmtuser'],
            'mgmtpass': CREDENTIALS['mgmtpass'],
            'supervisor_host': supervisor_host,
            'node': node_section,
        },
        use_sudo=True,
    )


def setup_supervisor(ring='MyRing'):
    """
    Install the supervisor.
    """
    put_installation_credentials()
    install_packages('scality-supervisor')

    if get_package_manager() == 'yum':
        start_service('httpd')
        start_service('scality-supervisor')
        if has_systemd():
            start_service('scality-supv2')

    setup_ringsh(ring, env.host)


def fake_disk(prefix='/scality/disk', quantity=1, size=40):
    """
    Setup a loop device, backed by a sparse file to serve as disk.

    :param prefix: mount prefix of the disks
    :type prefix: string
    :param quantity: number of disks to setup
    :param quantity: int
    :param size: sparse file size (GB)
    :type size: int
    """
    loop_path = '/var/fakedisk'
    sudo('mkdir -p {0:s}'.format(loop_path))
    for i in range(1, quantity + 1):
        mount_point = '{0:s}{1:d}'.format(prefix, i)
        backing_file = '{0:s}/{1:d}'.format(loop_path, i)
        sudo('mkdir -p {0:s}'.format(mount_point))
        sudo('truncate -s {0:d}G {1:s}'.format(size, backing_file))
        dev = sudo('losetup -f')
        sudo('losetup {0:s} {1:s}'.format(dev, backing_file))
        sudo('mkfs.ext4 -m 0 {0:s}'.format(dev))
        sudo('mount {0:s} {1:s}'.format(dev, mount_point))
        sudo('touch {0:s}/.ok_for_biziod'.format(mount_point))


def setup_node(supervisor_host, prefix='/scality/disk', metadisks=None,
               ring='MyRing'):
    """
    Bootstrap a Scality RING with a single store node.

    :param supervisor_host: hostname or ip of the supervisor for registration
        of the ring
    :type supervisor_host: string
    :param prefix: mount prefix of the disks (optional)
    :type prefix: string
    :param metadisks: mount prefix for bizobj.bin metadata (optional)
    :type metadisks: string
    :param ring: name of ring to create
    :type ring: string
    """
    if get_package_manager() == 'apt':
        install_packages('snmp')
    else:
        install_packages('net-snmp', 'net-snmp-utils')

    put_installation_credentials()
    upload_template(
        filename=abspath('assets/node/preseed'),
        destination='/tmp',
        context={
            'node_host': env.host,
            'supervisor_host': supervisor_host,
            'prefix': prefix,
            'metadisks': json.dumps(metadisks),
        },
    )

    # Install node.
    with shell_env(DEBIAN_FRONTEND='noninteractive'):
        install_packages('scality-node', 'scality-sagentd',
                         'scality-nasdk-tools')

    nodeconf = run('which scality-node-config')  # Required for CentOS
    sudo('{0:s} --resetconfig --preseed-file /tmp/preseed'.format(nodeconf))

    # Configure sagentd.
    sed(
        filename='/usr/local/scality-sagentd/snmpd_proxy_file.py',
        before='/tmp/oidlist.txt',
        after='/var/lib/scality-sagentd/oidlist.txt',
        use_sudo=True,
    )
    restart_service('scality-sagentd')
    restart_service('snmpd')

    # Create ring.
    retries = 10
    setup_ringsh(ring, supervisor_host, env.host)
    run('ringsh supervisor ringCreate {0:s}'.format(ring))
    run('ringsh supervisor serverAdd {0:s} {1:s} 7084'.format(ring, env.host))
    for retry in range(retries):
        time.sleep(5)
        cmd = run(
            command='ringsh supervisor nodeSetRing '
                    '{0:s} {1:s} 8084'.format(ring, env.host),
            warn_only=True,
        )
        if cmd.succeeded:
            break
    else:
        raise Exception("Unable to assign node to ring {0:s}".format(ring))
    for retry in range(retries):
        time.sleep(5)
        cmd = run(
            command='ringsh supervisor nodeJoin {0:s} 8084'.format(env.host),
            warn_only=True,
        )
        if cmd.succeeded:
            # Ensure node status
            cmd = run(
                command='ringsh supervisor nodeStatus {ip:s} 8084'.format(
                    ip=env.host
                ),
                warn_only=True,
            )
            if cmd.strip().startswith('RUN'):
                break
    else:
        raise Exception("Unable join node to ring {0:s}".format(ring))


def install_scality_manila_utils():
    """
    Install the scality-manila-utils python package.
    """
    install_packages('git', 'python-pip')
    sudo('pip install git+https://github.com/scality/scality-manila-utils.git')


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
