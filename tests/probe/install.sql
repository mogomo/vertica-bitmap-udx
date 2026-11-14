-- Probe functions (milestone M0). Variables: libfile, fenced (FENCED or NOT FENCED).
CREATE SCHEMA IF NOT EXISTS bitmap_probe;
CREATE OR REPLACE LIBRARY bitmap_probe.vbitmap_probe AS :libfile LANGUAGE 'C++';
CREATE OR REPLACE FUNCTION bitmap_probe.probe_popcount AS LANGUAGE 'C++'
    NAME 'ProbePopcountFactory' LIBRARY bitmap_probe.vbitmap_probe :fenced;
CREATE OR REPLACE TRANSFORM FUNCTION bitmap_probe.probe_partition AS LANGUAGE 'C++'
    NAME 'ProbePartitionFactory' LIBRARY bitmap_probe.vbitmap_probe :fenced;
-- Aggregates are created unfenced: the 26.3 manual states they cannot run fenced
-- (tests/probe/probes.sql checks that a FENCED aggregate is refused).
CREATE OR REPLACE AGGREGATE FUNCTION bitmap_probe.probe_count AS LANGUAGE 'C++'
    NAME 'ProbeCountFactory' LIBRARY bitmap_probe.vbitmap_probe NOT FENCED;
