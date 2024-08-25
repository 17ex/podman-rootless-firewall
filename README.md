# Podman: Firewall for rootless containers

## About

I run a bunch of containers with rootless podman,
and saw that there was (virtually) no information about
running them behind a firewall.

This is not meant to be some kind of project, this is more meant as a resource
and for documentation purposes, as I did not find much information about similar
approaches or really any good solutions for firewalls,
so either knowledge about this is not wide-spread, people don't want firewalls
for their (rootless) containers for some reason, or how to accomplish this
(and that this is very easy) is somehow clear to everyone except me.

Anyways, this is just meant to document a possible approach (and an example)
to firewalling rootless containers/networks, for future reference,
and in case anyone else might find this useful.

## Why

Of course, there is the host firewall, but there is no way (that I know of)
to tell apart packets originating from rootless containers and other traffic
from the corresponding user.

This means that:

- Containers/networks that are not internal have access to the host,
    and everything that the host has access to
- So, if you run containers that require eg. access to some port on the host,
    or access to the internet, or similar, it has access to everything else
    that that user has access to, so (often) unlimited outgoing access,
    and usually also all host ports.
- It would be possible to filter packets originating from a socket owned by the
    user running the containers, but this approach has numerous undesired side
    effects, such as that user not being able to pull new images if the user
    can't access the internet, and more.
    And even then, you could not have per-container rules, and any
    configuration/workarounds to problems introduced by it would get extremely
    messy and hard to maintain.

In essence, I don't see how you could accomplish this with the host firewall,
at least not without major side-effects and complications.

## How

You can simply configure the firewall inside of the rootless network namespace
of the user running the container(s).

And of course, you can just make systemd take care of starting the firewall etc.

See below (and the Caveats section) for an example, to see how you could go
about this.

## Example

This is a working sample configuration that starts a firewall and two containers
(one with internet access, and a db that does nothing, just to have a more
common setting with eg. one server and accompanying database).

First, create an user account, and copy everything in this repo into that user's
home directory:

```Shell
TESTUSER="fwtest"
useradd -d /home/$TESTUSER $TESTUSER
loginctl enable-linger $TESTUSER
cp -a /wherever/this/repo/is/* /home/$TESTUSER
# Alternatively, clone from git directly:
# git clone 'https://github.com/17ex/podman-rootless-firewall.git' /home/$TESTUSER
```

This example does the following/brings the following files with it:

- A 'Service' consisting of a server ```fw_test``` (just an alpine container
    doing nothing), and a postgresql database container,
    which is reachable by the alpine container, to simulate a setting
    with one application container that should be able to reach the internet
    (but nothing else), and its database.
- There is one network to enable communication between the alpine container and
    the db container, and one network that should allow the alpine container to
    reach the internet
- The internal (ie. in this case, the first aforementioned network) networks
    get (by default) a subnet range under the ```10.89.0.0/16``` prefix,
    and I usually assign non-internal networks a subnet range under the
    ```10.254.0.0/16``` prefix.
- It assumes that on the host on ports 80 and 443 there is some webserver
    listening, that ```fw_test``` should be able to reach.
    However, it should not be able to reach other ports on the host,
    and also no other private subnetworks that the host can reach (like eg. a
    VPN network), but it should be able to reach the internet.
- A firewall configuration file in
    ```${HOME}/.config/containers/firewall.nft```, in this example the firewall
    should permit ```fw_test``` to access the internet, but no private IP
    ranges, as well as **only** ports 80 and 443 on the host
    - In this configuration, I have arbitrarily assumed that the host has eg. IP
        addresses ```192.168.0.2``` and ```172.16.0.1```.
        Adapt these (in the set ```wl_host_ips```) to match your setting.
    - I don't really know what determines what the domain
        ```host.containers.internal``` should resolve to, but in my use case,
        where I have multiple IP addresses for my host, the IP address that this
        resolves to changes sometimes (maybe it always resolves to the IP
        address that was most recently assigned? No clue).
        Thus, in my deployment scenarios, I just whitelist all my host IP
        addresses there.
- The container units/networks are naturally defined in quadlet files as usual
- Furthermore, there is a systemd (user) service unit
    (```netns-firewall.service```) that starts/stops the firewall,
    and two additional systemd targets:
    - ```netns-firewall.target```, after which the user network namespace
        firewall is guaranteed to be up
    - ```container.target```, which starts the containers.
        This target specifies ```netns-firewall.target``` as a hard dependency,
        so it's guaranteed that the firewall is configured before any containers
        will be run
    - ```container.target``` is set to be ```WantedBy``` the default target,
        and will be enabled soon, so all of the above will be automatically run
        upon boot (because we enabled lingering for ```$TESTUSER```).

Next, we fix the file permissions, and enable ```container.target``` for
```$TESTUSER```:

```Shell
mkdir /home/$TESTUSER/.config/systemd/user/default.target.wants
ln -sf /home/$TESTUSER/.config/systemd/user/container.target /home/$TESTUSER/.config/systemd/user/default.target.wants
chown -R $TESTUSER:$TESTUSER /home/$TESTUSER
```

Of course, instead of linking, you can (but still need to run the ```chown```)
also enable it manually with ```systemctl``` after logging in as
```$TESTUSER```:

```Shell
machinectl shell $TESTUSER@
systemctl --user daemon-reload
systemctl --user enable container.target
logout
```

Now, we simply need to restart the session of ```$TESTUSER```, and everything
should be working:

```Shell
TESTUSERUID="$(id -u $TESTUSER)"
systemctl restart user@$TESTUSERUID
```

And now, you should be able to log into ```$TESTUSER```, and, if the containers
were started successfully, you should now be able to verify if the firewall is
working, eg. with

```Shell
machinectl shell $TESTUSER@
# This should work, ie. you can eg. just type GET and wget should
# be able to connect to the webserver, and either download something
# or respond with an error message that is not a timeout
podman exec -it systemd-fw_test wget 192.168.0.2
# If you have another web server in a reachable private network,
# eg. here with IP address 192.168.0.1, you should be able to verify
# now that the container can't connect to that server anymore,
# while your host user still can. So:
# This should not work:
podman exec -it systemd-fw_test wget 192.168.0.1
# While (still as the same user) this should:
wget 192.168.0.1
# Also, if you have other open ports on your server
# (but that are not whitelisted in the container firewall),
# eg. assuming you have a SMTP server listening on port 25 that the
# container should not be able to communicate with, also test that
# eg.
podman exec -it systemd-fw_test nc 192.168.0.2 25
# should not work, but again,
nc 192.168.0.2 25
# should work on the host/as the user running the containers.
# Finally, the container should still have working internet access,
# so
podman exec -it systemd-fw_test wget archlinux.org
# should also work.
```

## Caveats

- The example only works (afaik) with the netavark backend. It probably will/can
    work in other settings with no, some or a lot of tinkering.
- Netavark needs a specific configuration of the firewall, or it will refuse to
    work. I don't know exactly what is required, but you need to set up:
    - an ip nat table with `PREROUTING`, `OUTPUT` and `POSTROUTING` hooked on
        the corresponding hooks (see example)
        - Netavark will populate this itself. They just need to be present
        - If you set the firewall as in the example, networking of all running
            containers will break!
        - This is a non-issue if you start the firewall before running any
            containers as you should, but if your workflow requires otherwise
            be sure to either not flush that table, or restore it afterwards.
    - an ip filter table with a `FORWARD` chain hooked on the forward hook
        - Netavark will add rules to that chain that will allow all traffic
            to/from any container that is added
        - If it is not hooked on the forward hook, Netavark won't work.
        - That means that later on, Netavark will constantly modify the firewall
            rules
        - We can circumvent this issue, because:
            - In nftables, packets (for some hook) will _all_ chains that are
                hooked up on that hook
            - So, we just hook up a second chain (in the example `FWD`), which
                we use to place our firewall rules into
            - If we set this chain to a lower priority, it will be traversed
                first. I don't think the priority actually matters in the end,
                but it's perhaps easier to think about if you think of it as
                'the `FWD` chain is traversed first, and only then the chain
                that Netavark will modify will be taken into account'
            - Netavark will (as of writing this) only ever add accepting rules
            - A packet will be dropped if it is dropped in any chain, and
                accepted if all chains accept it, so
            - Ultimately, all Netavark rules will not change the firewall
                behavior. Just make it slightly more inefficient, as more chains
                need to be traversed.
- You need to (or should) set different IP ranges for networks that are
    internal, and for those that are not, so the firewall rules can take that
    into account
- Obviously, YMMV
- This is not meant to be an easily (with minor adaptations) copy-pastable
    solution. This is intended for people that know what they are doing.
    Do not think that just because you did that, you have a working firewall!
- Obviously, when playing around with this/deploying a firewall in this setting,
    **test** whether everything works as intended, ie.
    - Verify whether everything that should be allowed is allowed, and whether
        container networking itself still works
    - Verify whether everything that should not be accessible is actually
        inaccessible.
    - Do not blindly trust that everything will work

## See also

- There was work done to achieve something similar in a different
    (maybe more elegant/portable?) way using OCI hooks
    (see here: [Podman PR #10704](https://github.com/containers/podman/pull/10704),
    and also the issue linked in the PR for more info on this), but the corresponding
    PR (adding a new hook) wasn't finished, and without it, it seems it may
    not work reliably/only in specific settings.
- Apart from that, I didn't really find useful information about this and
    tinkered with this myself until I got something that works well.
    If you know other good resources, feel free to open an issue/PR with
    updates.
