set -u
cd ~/vertica-bitmap-udx
R="bench/record.sh --area=vertica"
$R --run=build-person-t10 --purpose="lifecycle build, person index + daily sets, with validation" --scale="10 M people, 200 M interests, 100 M events" --path="snapshot.sh build --daily --publish" -- scripts/snapshot.sh build --tenant=10 --domain=person --snapshot=1 --source-snapshot=1 --watermark="2026-11-01 00:00:00" --daily --publish
$R --run=build-device-t10 --purpose="lifecycle build, device index, with validation" --scale="2 M devices" --path="snapshot.sh build --publish" -- scripts/snapshot.sh build --tenant=10 --domain=device --snapshot=1 --source-snapshot=1 --watermark="2026-11-01 12:00:00" --publish
$R --run=build-asset-t10 --purpose="lifecycle build, asset index, with validation" --scale="5 M assets, 10 M sources" --path="snapshot.sh build --publish" -- scripts/snapshot.sh build --tenant=10 --domain=asset --snapshot=1 --source-snapshot=1 --watermark="2026-11-01 00:00:00" --publish
$R --run=storage-t10 --purpose="storage of source and index tables" --scale="default (tenant 10) + fixture tenants" --path="projection_storage" -- bench/storage.sh
echo ALL_DONE
