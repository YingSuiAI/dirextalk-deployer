# Split deployment sources

`dirextalk-message-server/deploy/split-agent` is the canonical source for the
split Compose topology and all message/Agent initialization helpers. This
directory owns only the cloud edge overlay and remote bootstrap wrapper.

Run `scripts/render/render-split-userdata.sh` from a checkout next to
`dirextalk-message-server`, or set `DIREXTALK_MESSAGE_SERVER_ROOT` to that
repository. The renderer packages the canonical files into the remote bundle;
do not copy them here.
