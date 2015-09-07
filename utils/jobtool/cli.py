#!/usr/bin/python

import subprocess
import time

import click
import novaclient.client
import paramiko


# NOVA related functions


def find_available_ip(client):
    for ip in client.floating_ips.list():
        if ip.fixed_ip is None:
            return ip


def find_server(client, server_name):
    for server in client.servers.list():
        if server.name == server_name:
            return server


def find_image(client, image_name):
    for image in client.images.list():
        if image.name == image_name:
            return image


def create_floating_ip(client):
    return client.floating_ips.create()


def start_server(nova_client, image_name, server_name, server_flavor,
                 ssh_key_name, add_floating_ip=True):

    image = find_image(nova_client, image_name)
    assert image is not None, "No image %s found" % image_name

    server = nova_client.servers.create(
        name=server_name, image=image, flavor=server_flavor,
        key_name=ssh_key_name)
    while server.status != 'ACTIVE':
        time.sleep(2)
        print "Waiting for server to boot"
        server = find_server(nova_client, server_name)
        assert server is not None, "No server '%s' found" % server_name

    floating_ip = None
    if add_floating_ip:
        floating_ip = create_floating_ip(nova_client)
        assert floating_ip is not None, "No available IP found"
        server.add_floating_ip(floating_ip)
    private_ip = server.networks['private'][0]

    return server, private_ip, floating_ip


def find_ip(client, ip):
    for ip_obj in client.floating_ips.list():
        if ip_obj.ip == ip:
            return ip_obj


# END NOVA related functions


class SSHClientWrapper(object):

    def __init__(self, client, user):
        self.client = client
        self.user = user

    @property
    def install_cmd(self):
        if self.user == 'centos':
            install_cmd = 'yum -y install'
        else:
            install_cmd = 'apt-get -y install'
        return install_cmd

    def install(self, *args):
        cmd = "sudo %s %s" % (self.install_cmd, ' '.join(args))
        self.command(cmd)

    def command(self, cmd):
        stdin, stdout, stderr = self.client.exec_command(cmd, get_pty=True)
        print stdout.read()
        print stderr.read()

    def create_pkey(self):
        cmd = ["openssl genrsa -aes128 -passout pass:x",
               "-out server.pass.key 2048"]
        self.command(" ".join(cmd))
        cmd = ["openssl rsa -passin pass:x",
               "-in server.pass.key -out /home/%s/.ssh/id_rsa"
               % self.user]
        self.command(" ".join(cmd))
        self.command("chmod go-rw ~/.ssh/id_rsa")
        self.command("rm server.pass.key")

    def clone_repo(self, repo, branch=None):
        command = "git clone"
        if branch:
            command += " -b %s" % branch
        command += " %s" % repo
        self.command(command)

    def write_file(self, data, path, mode=None):
        sftp_client = self.client.open_sftp()
        f = sftp_client.open(path, mode='w')
        f.write(data)
        f.close()
        if mode:
            sftp_client.chmod(path, mode)


def interactive_connect(user, ip, ssh_key):
    cmd = ["ssh -A -tt -oBatchMode=yes -oUserKnownHostsFile=/dev/null -i",
           "%s -oStrictHostKeyChecking=no" % ssh_key,
           "-oLogLevel=error %s@%s" % (user, ip)]
    subprocess.call(" ".join(cmd), shell=True)


class ManilaTempestJob(object):
    """ mandatory job_params : JOB_GIT_REVISION
    """

    job_name = "manila-tempest"

    def __init__(self, nova_client, ssh_wrapper, repo, raw_jo_params,
                 user, extra_image, extra_server, ssh_key_name,
                 server_flavor):
        self.nova_client = nova_client
        self.ssh_wrapper = ssh_wrapper
        self.repo = repo
        self.user = user
        self.extra_image = extra_image
        self.extra_server = extra_server
        self.ssh_key_name = ssh_key_name
        self.server_flavor = server_flavor
        self.job_params = self._read_job_params(raw_jo_params)

    def _read_job_params(self, raw_job_params):
        result = dict()
        for param_value in raw_job_params:
            [param, value] = param_value.split('=')
            result[param] = value
        return result

    def run(self):
        self.ssh_wrapper.install('git', 'vim')
        self.ssh_wrapper.create_pkey()
        self.ssh_wrapper.clone_repo(
            self.repo, self.job_params['JOB_GIT_REVISION'])
        extra_server, private_ip, floating_ip = start_server(
            self.nova_client, self.extra_image, self.extra_server,
            self.server_flavor, self.ssh_key_name, add_floating_ip=False)
        self._write_tosource(private_ip)
        self._write_clean()

    def _write_tosource(self, private_ip):
        data = """#!/bin/bash
export LC_ALL=en_US.UTF-8
export WORKSPACE=$(pwd)/openstack-ci-scripts
export JOB_NAME="%s"
export JCLOUDS_IPS="%s"
""" % (self.job_name, private_ip)
        if self.job_params:
            for param, value in self.job_params.items():
                data += "export %s=%s\n" % (param, value)

        path = '/home/%s/tosource.sh' % self.user
        self.ssh_wrapper.write_file(data, path)

    def _write_clean(self):
        data = """#!/bin/bash -xue
openstack-ci-scripts/devstack/unstack.sh
cd openstack-ci-scripts
git clean -ffd
git pull origin manila-tempest
rm /etc/manila/manila.conf
sudo rm -r /opt/stack/manila-scality
"""
        path = '/home/%s/clean.sh' % self.user
        self.ssh_wrapper.write_file(data, path, 0755)


@click.group()
@click.option('--os-username', envvar='OS_USERNAME', required=True)
@click.option('--os-password', envvar='OS_PASSWORD', required=True)
@click.option('--os-tenant-name', envvar='OS_TENANT_NAME', required=True)
@click.option('--os-auth-url', envvar='OS_AUTH_URL', required=True)
@click.option('--os-compute-api-version', envvar='OS_COMPUTE_API_VERSION',
              required=True)
@click.pass_context
def main(ctx, os_username, os_password, os_tenant_name, os_auth_url,
         os_compute_api_version):
    client = novaclient.client.Client(
        os_compute_api_version, os_username, os_password, os_tenant_name,
        os_auth_url)
    ctx.obj = {'nova_client': client}


@main.group()
@click.option('--image', required=True,
              help='Base image used to spawn from')
@click.option('--server', required=True,
              help='Arbitrary name that will be given to the VM')
@click.option('--server-flavor', required=True,
              help='Name or ID of the server flavor (S - M - XL,...)')
@click.option('--user', required=True,
              help='User that has credentials to connect to the VM')
@click.option('--ssh-key-name', required=True,
              help='Nameof the ssh key that will attributed to the VM'
                   '(check your OS infra available keys)')
@click.option('--ssh-key', required=True,
              help='PAth to the ssh key on your local machine')
@click.option('--repo', required=True,
              help='Repository that will get cloned on the VM')
@click.option('--param', multiple=True,
              help='KEY=VALUE parameter. Can be specified multiple times.')
@click.pass_context
def bootstrap(ctx, image, server, server_flavor, user,
              ssh_key_name, ssh_key,  repo, param,):
    """ Bootstrap the job specified in the sub command :
    Spawn a VM, clone the repo, perform some job specific operations
    amd start an interactive SSH connection with the server.
    """
    server, private_ip, floating_ip = start_server(
        ctx.obj['nova_client'], image, server,
        server_flavor, ssh_key_name)
    time.sleep(30)
    ssh_client = paramiko.SSHClient()
    ssh_client.set_missing_host_key_policy(paramiko.MissingHostKeyPolicy())
    ssh_client.connect(
        floating_ip.ip, username=user,
        key_filename=ssh_key)
    ctx.obj['ssh_wrapper'] = SSHClientWrapper(ssh_client, user)
    ctx.obj['bootstrap-params'] = ctx.params
    ctx.obj['ip'] = floating_ip.ip


@bootstrap.command()
@click.option('--extra-image', required=True)
@click.option('--extra-server', required=True)
@click.pass_context
def manila_tempest(ctx, extra_image, extra_server):
    """manila-tempest job specific operations :
    an additionnal VM will gets spawned.
    """
    cli_args = ctx.obj['bootstrap-params'].copy()
    cli_args.update(ctx.params)
    ManilaTempestJob(
        ctx.obj['nova_client'], ctx.obj['ssh_wrapper'], cli_args['repo'],
        cli_args['param'], cli_args['user'], cli_args['extra_image'],
        cli_args['extra_server'], cli_args['ssh_key_name'],
        cli_args['server_flavor']).run()
    interactive_connect(cli_args['user'], ctx.obj['ip'], cli_args['ssh_key'])


@main.command()
@click.option('--ssh-key', required=True)
@click.argument('user', nargs=1)
@click.argument('server', nargs=1)
@click.pass_context
def connect(cont, ssh_key, user, server):
    """ Start an interactive SSH connection with specified server.
    """
    client = cont.obj['nova_client']
    server_obj = find_server(client, server)
    assert server_obj is not None, "No server '%s' found" % server
    networks = server_obj.networks
    assert 'private' in networks and len(networks['private']) == 2, \
        "No public IP found"
    interactive_connect(user, networks['private'][1], ssh_key)


@main.command()
@click.argument('server', nargs=-1, required=True)
@click.pass_context
def kill(cont, server):
    """ Destroy the specified servers.
    For each server, unallocate its floating IP if it has one.
    """
    client = cont.obj['nova_client']
    for srv in server:
        server_obj = find_server(client, srv)
        assert server_obj is not None, "No server '%s' found" % srv

        if len(server_obj.networks['private']) > 1:
            floating_ip = server_obj.networks['private'][1]
            server_obj.remove_floating_ip(floating_ip)
            ip_obj = find_ip(client, floating_ip)
            assert ip_obj is not None, "No IP '%s' found" % floating_ip
            client.floating_ips.delete(ip_obj)

        server_obj.delete()


@main.command()
@click.option('--image', required=True,
              help='Base image used to spawn from')
@click.option('--server', required=True,
              help='Arbitrary name that will be given to the VM')
@click.option('--server-flavor', required=True,
              help='Name or ID of the server flavor (S - M - XL,...)')
@click.option('--ssh-key-name', required=True,
              help='Nameof the ssh key that will attributed to the VM'
                   '(check your OS infra available keys)')
@click.pass_context
def start(ctx, image, server, server_flavor, ssh_key_name):
    """Start a server.
    """
    server, private_ip, floating_ip = start_server(
        ctx.obj['nova_client'], image, server,
        server_flavor, ssh_key_name)
    click.echo("Server %s started, IP: %s" % (server, floating_ip.ip))


if __name__ == '__main__':
    main()
