# Changelog

**autorate.sh** is a script that automatically adapts
[CAKE Smart Queue Management (SQM)](https://www.bufferbloat.net/projects/codel/wiki/Cake/)
bandwidth settings by measuring traffic load and RTT times.
Read the [README](./README.md) file for more details.
This is the history of changes.

## 2021-12-10

- One-way delay experiments in `autorate.sh`.
See if we can improve accuracy of the upload and download settings by getting a more accurate
measurement of the delay in each direction.
- Experiment with `hping`
- Revert to `/usr/bin/ping` - don't use `hping`

## 2021-11-23

- Update/simplify `awk` code for calculating delays and bandwidth settings
