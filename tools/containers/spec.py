#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""spec.py - the docker and podman packs: each job, every metric it prints
and how to read it. gen.py makes the scripts' headers and pack.config from
this."""

UP = ('up', '1 when {E} answers, else 0 (and nothing more is read)')
NAME = 'tagged name=<the container\'s name>'


def status(e, engine):
    m = [UP]
    if e == 'docker':
        m.append(('version', 'always 1, tagged version=<the engine\'s version>, api=<its API\'s version> and os=<linux or windows: the containers it runs>'))
    else:
        m.append(('version', 'always 1, tagged version=<Podman\'s version>, os=<linux> and rootless=<true or false>'))
        m.append(('rootless', '1 when these are an account\'s own containers (rootless), 0 when they are root\'s'))
    m += [('containers', 'containers it holds, running or not'),
          ('running', 'of those, running'),
          ('paused', 'paused')]
    if e == 'docker':
        m.append(('restarting', 'between two starts: the container stopped, and its restart policy is starting it again. One that stays here is in a loop'))
    m += [('exited', 'stopped: they ran, and ended'),
          ('created', 'created, and never started')]
    if e == 'docker':
        m.append(('dead', 'that the engine could not remove'))
    m += [('unhealthy', 'running, with a health check that fails'),
          ('health_starting', 'running, with a health check that has not passed yet'),
          ('exited_nonzero', 'stopped with an exit code other than 0')]
    if e == 'podman':
        m += [('restarts_total_count', 'times a restart policy started a container again, over all of them (a running total): under Podman a container in a loop reads as running, and this is what rises'),
              ('pods', 'pods these containers are in')]
    m += [('images', 'images it holds'),
          ('cpus', 'processors %s sees' % engine),
          ('memory_bytes', 'memory %s sees' % engine)]
    if e == 'docker':
        m.append(('warnings', 'what the engine warns about itself (docker info prints them)'))
    return m


def containers(e):
    m = [UP, ('containers', 'containers it holds, running or not')]
    if e == 'docker':
        m.append(('containers_restarting', 'of those named below, between two starts'))
    m += [('containers_unhealthy', 'of those named below, with a health check that fails'),
          ('containers_oom_killed', 'killed for memory: the kernel ended them at their limit'),
          ('containers_exited_nonzero', 'stopped with an exit code other than 0'),
          ('restarts_total_count', 'times a restart policy started them again (a running total, over those named below)'),
          ('running', '1 when the container runs, 0 when it does not (stopped, paused, created%s), %s and state=<its state>' % (', between two starts' if e == 'docker' else '', NAME)),
          ('restarts_count', 'times its restart policy started it again (a running total), ' + NAME),
          ('oom_killed', '1 when it was killed for memory, ' + NAME),
          ('uptime_seconds', 'for one that runs: seconds since it last started, ' + NAME),
          ('healthy', 'for one with a health check that has run: 1 healthy, 0 unhealthy, ' + NAME),
          ('exit_code', 'for one that stopped: its exit code, ' + NAME),
          ('containers_not_shown', 'past the first 100 by name ({M}), how many were not named')]
    return m


def resources(e):
    m = [UP, ('containers_measured', 'running containers measured'),
         ('memory_total_bytes', 'memory they use, together'),
         ('memory_fullest_pct', 'the fullest of those with a memory limit: its memory, as a share of its limit')]
    if e == 'docker':
        m.append(('cpu_throttled_containers', 'containers held back at their CPU limit at least once since they started'))
    m.append(('cpu_seconds_count', 'CPU time it has used since it started, in seconds (a running total: its rate is the processors it uses), ' + NAME))
    if e == 'docker':
        m.append(('cpu_throttled_seconds_count', 'time it was held back at its CPU limit (a running total), ' + NAME))
    m += [('memory_bytes', 'memory it uses, without the file cache that can be given back, ' + NAME),
          ('memory_limit_bytes', 'its memory limit, 0 when it has none, ' + NAME),
          ('memory_pct', 'for one with a limit: its memory, as a share of it, ' + NAME),
          ('pids', 'processes and threads in it, ' + NAME),
          ('network_rx_bytes_count', 'bytes it received, over its networks (a running total), ' + NAME),
          ('network_tx_bytes_count', 'bytes it sent (a running total), ' + NAME),
          ('block_read_bytes_count', 'bytes it read from disk (a running total), ' + NAME),
          ('block_write_bytes_count', 'bytes it wrote to disk (a running total), ' + NAME),
          ('containers_not_shown', 'past the first 100 by name ({M}), how many were not measured')]
    return m


def disk(e):
    m = [UP, ('images', 'images it holds'),
         ('images_unused', 'of those, used by no container'),
         ('images_dangling', 'with no name left: an older build of a tag that moved on'),
         ('images_bytes', 'disk the images take'),
         ('images_reclaimable_bytes', 'of that, what removing the unused ones would give back'),
         ('containers', 'containers it holds, running or not'),
         ('containers_bytes', 'disk the containers take: what each wrote in its own layer')]
    if e == 'docker':
        m.append(('containers_stopped_bytes', 'of that, held by containers that are not running'))
    else:
        m.append(('containers_reclaimable_bytes', 'of that, held by containers that are not running'))
    m += [('container_bytes', 'what one container wrote in its own layer, the 20 largest, ' + NAME),
          ('container_bytes_not_shown', 'past those 20, how many were left out'),
          ('volumes', 'volumes it holds'),
          ('volumes_unused', 'of those, used by no container'),
          ('volumes_bytes', 'disk the volumes take')]
    if e == 'docker':
        m += [('volumes_unused_bytes', 'of that, in volumes no container uses'),
              ('volume_bytes', 'the size of one volume, the 20 largest, tagged name=<the volume\'s name>'),
              ('volume_bytes_not_shown', 'past those 20, how many were left out'),
              ('build_cache_bytes', 'disk the build cache takes'),
              ('build_cache_reclaimable_bytes', 'of that, not in use by a build')]
    else:
        m.append(('volumes_reclaimable_bytes', 'of that, in volumes no container uses'))
    return m


def jobs(e, engine, most):
    def fix(ms):
        return [(n, t.replace('{E}', engine).replace('{M}', most)) for n, t in ms]
    loop = ('restarting above 0 on two runs in a row: a container in a restart loop (%s_containers names it, by restarts_count rising)' % e
            if e == 'docker' else
            'restarts_total_count rising: a container in a restart loop, which Podman shows as running (podman_containers names it)')
    return {
        'status': dict(
            title='%s: up, its version, and its containers by state' % engine,
            about=['Whether %s answers, and what it holds: containers running, paused, stopped%s, those whose health check fails, those that ended with an error, and its images.' % (engine, ', restarting' if e == 'docker' else '')],
            metrics=fix(status(e, engine)), every='1m', max='30s',
            reading=dict(
                Healthy='up 1; unhealthy 0; %s; exited_nonzero steady (a job that failed once stays counted until its container is removed).' % ('restarting 0' if e == 'docker' else 'restarts_total_count flat'),
                Watch='health_starting above 0 for minutes: a health check that never passes. running lower than it was: something stopped and nothing started it again.',
                Act='up 0: %s. unhealthy above 0. %s.' % ('the engine is down, and so is every container without live restore' if e == 'docker' else 'Podman cannot be asked (on a Mac, its machine is stopped)', loop))),
        'containers': dict(
            title='each container: running or not, restarts, health, exit code, killed for memory',
            about=['Each container by name (the first 100; {M} sets another number): whether it runs, how many times its restart policy has started it again, whether its health check passes, the exit code of one that stopped, and whether the kernel killed it for memory.'.replace('{M}', most)],
            metrics=fix(containers(e)), every='1m', max='1m',
            reading=dict(
                Healthy='running 1 for every container meant to run; restarts_count flat; healthy 1; oom_killed 0.',
                Watch='restarts_count rising slowly: a container that falls over now and then. uptime_seconds small on a container nobody restarted.',
                Act='running 0 on a container meant to run. restarts_count rising on every run: a restart loop. healthy 0. oom_killed 1: it needs more memory, or leaks it. exit_code other than 0 on a job that should have succeeded (137: killed; 139: it crashed; 143: stopped by a signal).')),
        'resources': dict(
            title='each running container: CPU, memory against its limit, processes, network and disk',
            about=['Each running container by name (the first 100; {M} sets another number): the CPU time it has used, its memory and how near its limit that is, its processes, and what it has sent, received, read and written.'.replace('{M}', most)],
            metrics=fix(resources(e)), every='1m', max='2m',
            reading=dict(
                Healthy='memory_pct well under 100; memory_bytes steady for a container doing steady work%s.' % ('; cpu_throttled_seconds_count flat' if e == 'docker' else ''),
                Watch='memory_bytes climbing run after run with no more work to do: a leak, on its way to the limit. %spids climbing: processes or threads that are never reaped.' % ('cpu_throttled_seconds_count rising: its CPU limit holds it back. ' if e == 'docker' else ''),
                Act='memory_fullest_pct above 90: a container about to be killed for memory (memory_pct says which). pids near the limit of the machine.')),
        'disk': dict(
            title='the disk %s uses: images, containers, volumes%s, and what could be given back' % (engine, ' and the build cache' if e == 'docker' else ''),
            about=['What %s keeps on disk and how much of it is in use: images (unused ones, and those with no name left), what containers wrote in their own layers, volumes (and those no container uses)%s. A full disk under %s stops every container on the machine at once.' % (engine, ', and the build cache' if e == 'docker' else '', engine),
                   'How full the disk itself is, is the base pack\'s to say (its disk job): this job says what is on it.'],
            metrics=fix(disk(e)), every='15m', max='5m',
            reading=dict(
                Healthy='images_bytes and volumes_bytes steady; images_reclaimable_bytes a small share.',
                Watch='images_dangling or images_reclaimable_bytes growing: builds and pulls that nothing clears. container_bytes large and growing: a container writing into its own layer what belongs in a volume (or logs nobody rotates).',
                Act='any of them growing run after run while the base pack shows the disk filling. volumes_unused %s large: data left behind by containers that are gone, to keep or to remove on purpose.' % ('with volumes_unused_bytes' if e == 'docker' else 'with volumes_reclaimable_bytes'))),
    }


PACKS = {
    'docker': dict(
        version='1.0.0', platforms=['linux', 'macos', 'windows'],
        description='Docker: whether the engine answers, its containers by state, each container (running, restarts, health, exit code, killed for memory), each one\'s CPU, memory against its limit, network and disk, and the disk the engine uses (images, containers, volumes, build cache)',
        works_with='Docker Engine 20.10 and later (API 1.41), Linux and Windows containers, and Docker Desktop (tested: 29.9, 29.10)',
        programs=dict(linux='bash, curl, jq', macos='bash, curl, jq', windows='PowerShell 5.1 or later'),
        config_about='docker - a Docker engine, from its own API: is it up, what state is every container in (running, restarting, unhealthy, killed for memory), what does each use (CPU, memory against its limit, network, disk), and how much disk do images, containers, volumes and the build cache take. Linux, macOS and Windows. See SPECIFICATION.md section 18.10 for this format.',
        env=['DOCKER_HOST'],
        needs=['an account that may use the engine: root, or a member of the docker group (Linux); an administrator, or a member of the group daemon.json names (Windows). That is as good as root on the machine, as it is for anyone who can run docker',
               'its address, where it is not the default (unix:///var/run/docker.sock; on Windows npipe:////./pipe/docker_engine): env = DOCKER_HOST=... on each job',
               'for the engine\'s own CPU and memory (dockerd): the base pack\'s processes job; for how full the disk is, its disk job'],
        how_sh='Reads the Docker engine\'s API at DOCKER_HOST (unix:///var/run/docker.sock by default) with curl and jq. Every request is a GET: nothing is started, stopped, removed or pruned.',
        how_ps='Reads the Docker engine\'s API at DOCKER_HOST (npipe:////./pipe/docker_engine by default) with .NET alone. Every request is a GET: nothing is started, stopped, removed or pruned.',
        requires_sh='bash, curl 7.40 or later, and jq', requires_ps='Windows PowerShell 5.1 or PowerShell 7',
        exits_sh='0 on success, the engine up or down; 1 if curl or jq is missing, DOCKER_HOST is wrong, this account may not use the engine, or what answers is not a Docker engine',
        exits_ps='0 on success, the engine up or down; 1 if DOCKER_HOST is wrong, this account may not use the engine, or what answers is not a Docker engine',
        jobs=jobs('docker', 'the engine', 'DOCKER_MOST')),
    'podman': dict(
        version='1.0.0', platforms=['linux', 'macos'],
        description='Podman: whether it answers, its containers by state, each container (running, restarts, health, exit code, killed for memory), each one\'s CPU, memory against its limit, network and disk, and the disk it uses (images, containers, volumes)',
        works_with='Podman 4.0 and later, rootless and as root (tested: 5.8 on Linux)',
        programs=dict(linux='bash, podman, jq', macos='bash, podman, jq'),
        config_about='podman - Podman, asked with its own command: can it be asked, what state is every container in (running, unhealthy, killed for memory, restarted again and again), what does each use (CPU, memory against its limit, network, disk), and how much disk do images, containers and volumes take. Linux and macOS. See SPECIFICATION.md section 18.10 for this format.',
        env=['CONTAINER_HOST'],
        needs=['Podman keeps containers by account: Vigil reads those of the account it runs as. As root, root\'s containers; as another account, that account\'s own (rootless) and no one else\'s',
               'for another Podman than this account\'s own (a remote one, a podman machine that is not the default): env = CONTAINER_HOST=... on each job, as for the podman command',
               'for the machine\'s CPU and memory: the base pack\'s processes job; for how full the disk is, its disk job'],
        how_sh='Asks Podman with its own command, as the account the job runs as, and reads the answers with jq. It only reads (info, ps, inspect, stats, system df, images): nothing is started, stopped, removed or pruned.',
        how_ps='',
        requires_sh='bash, podman and jq', requires_ps='',
        exits_sh='0 on success, Podman answering or not; 1 if podman or jq is missing, or Podman answers with an error',
        exits_ps='',
        jobs=jobs('podman', 'Podman', 'PODMAN_MOST')),
}
