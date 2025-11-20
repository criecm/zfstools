--[[
   usage: delsnapsmatchbut.lua base/zfs include_expr [exclude_expr [exclude_expr]…]
   example: zfs program zpool zfs-program/delsnapsmatchbut.lua zdata/shares/home1 fou%-chi%-%d+ fou%-chi%-12345678
     will delete recursively all snaps matching @fou-chi-[0-9]+ but not @fou-chi-12345678
   for pattern syntax: https://www.lua.org/manual/5.3/manual.html#6.4.1
]]
deleted = {}
skipped = {}
failed = {}
excludes = {}
 
function match_excludes(truc)
  for j,excl in pairs(excludes) do
    if string.match(truc, "@"..excl) then
      return true
    end
  end
  return false
end

function destroy_recursive(root)
    for child in zfs.list.children(root) do
        destroy_recursive(child)
    end
    snaplist = ""
    for snap in zfs.list.snapshots(root) do
        snaplist = snaplist .. "," .. snap
        if string.match(snap, "@"..match) and not match_excludes(snap) then
            err = 0
            err = zfs.sync.destroy({snap, defer=true})
            if  (err ~= 0) then
             failed[snap] =     err
            else
             table.insert(deleted,snap)
            end
        else
            table.insert(skipped,snap)
        end
    end
end
 
args = ...
argv = args["argv"]

results = {}
match = argv[2]
for i=3,#argv,1 do
  table.insert(excludes,argv[i])
end

destroy_recursive(argv[1])
 
results["deleted"] = deleted
results["failed"] = failed
results["skipped"] = skipped
return results
