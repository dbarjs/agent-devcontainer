# Sheldon plugin: expose the adc CLI on the host.
# Containers never source this — the images bake adc into /usr/local/bin.
path=("${0:A:h}/cli" $path)
