# tests zfs destroy snapshots

compare zfs shell operations with zfs-program lua
when large number of snapshots involved AND need for more fine-grained
than `zfs destroy -r zdata/test@%test-999` that would destroy all snapshots older
than @test-999 one and keep all younger ones.

Here we test a more real-world example:
We want to delete expression-selected snapshots (eg: only work on some well-named snapshots), keeping some of them using another expr (regex for shell, lua expr for lua)

## Results
The winner is LUA, faster and cheaper. No possible debate.

100 times faster than equivalent shell script (safe one), 

* with (2000x3)-(3x20) snapshots to delete 
  * lua: 24s, 0.03s CPU
  * safe shell: ~2424s (40m24s), 54s CPU
  * unsafe shell: 970s (16m11s), 21s CPU
* with (1000x4)-(4x10) snapshots
  * lua: 16s, 0.05s CPU
  * safe shell: 3960s (1h06m10s), 92s CPU
  * unsafe shell: 983s (16m23s), 26s CPU

## Methodology
All tests have been run on two different hosts:
  * 2000x3 on a workstation with 2 4T sata drives mirror and cache/log on a single customer-grade ssd
  * 1000x4 on a server with a 10x2T sas raidz-2, cache on two enterprise-grade ssd and log on a two ssd mirror

FreeBSD 14.3p5 amd64

### prepare
create dataset hierarchy and take 1000 or 2000 snapshots with real data difference

this is *very* long (~20 minutes here for 1000 snaps), but not what we try to optimize here
```shell
zfs create -o mountpoint=/mnt/test zdata/test;
zfs create zdata/test/un;
zfs create zdata/test/deux;
zfs create zdata/test/trois;
for i in {0001..1000}; do
  for sub in "" /un /deux /trois; do
    echo "$i" > /mnt/test${sub}/test$i;
  done;
  zfs snapshot -r zdata/test@test-${i};
done;
```

### tests

destroy recursively all `@test-[0-9][0-9][0-9][0-9]` snapshots BUT keeping all `@test-[0-9][0-9]34` ones

#### shell + zfs destroy
```shell
echo "zfs list -r -tsnap -Honame zdata/test | grep '@test-[0-9]\{4\}' | grep -v '@test-[0-9][0-9]34' | xargs -L1 zfs destroy" | time sh
```
* with 2000 snapshots on zdata/test/{un,deux}:
    15.23s user 38.87s system 2% cpu 40:23.83 total
* with 1000 snapshots on zdata/test/{un,deux,trois}:
    21.70s user 70.33s system 2% cpu 1:06:10.76 total

#### shell + zfs destroy -r
this method is quicker but less safe: it may let some sub-filesystem snapshots alone if the same snap doesn't exist on the parent
```shell
echo "zfs list -tsnap -Honame zdata/test | grep '@test-[0-9]\{4\}' | grep -v '@test-[0-9][0-9]34' | xargs -L1 zfs destroy -r" | time sh
```
* with 2000 snapshots on zdata/test/{un,deux}:
    5.73s user 14.99s system 2% cpu 16:10.54 total
* with 1000 snapshots on zdata/test/{un,deux,trois}:
    5.81s user 20.07s system 2% cpu 16:23.13 total

#### zfs program lua
<< /root/destroysnapselect.lua:
```lua
succeeded = {}
failed = {}
 
function destroy_recursive(root)
    for child in zfs.list.children(root) do
        destroy_recursive(child)
    end
    snaplist = ""
    for snap in zfs.list.snapshots(root) do
        snaplist = snaplist .. "," .. snap
        if string.match(snap, "@"..match) and not string.match(snap, "@"..but) then
            err = 0
            err = zfs.sync.destroy({snap,defer=true})
            if  (err ~= 0) then
             failed[snap] =     err
            else
             succeeded[snap] = err
            end
        else
            failed[snap] = "skip"
        end
    end
end
 
args = ...
argv = args["argv"]
results = {}
match = argv[2]
but = argv[3]
destroy_recursive(argv[1])
 
results["succeeded"] = succeeded
results["failed"] = failed
return results
```
```shell
time zfs program zdata /root/destroysnapselect.lua zdata/test test%-%d%d%d%d test%-%d%d34
```

* with 2000 snapshots on zdata/test/{un,deux}:
    0.01s user 0.02s system 0% cpu 23.667 total
* with 1000 snapshots on zdata/test/{un,deux,trois}:
    0.01s user 0.04s system 0% cpu 16.085 total
