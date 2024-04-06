# maint README

These scripts are for maintainers of `cake-autorate` to simplify
some housekeeping tasks. If you are a `cake-autorate` user, you
should have no interest in these scripts.

## Octave Formatter Guide

[@moeller0](https://github.com/moeller0) is the primary developer of the `fn_parse_autorate_log.m` script.
However, due to inconsistencies in the formatting of the script, it is difficult to track changes in the script using `git`.

While it would be ideal that the script is written in a consistent style, we do not want to impose a style on anyone and break anybody's workflow. Instead, we can use a `textconv` filter to convert the script to a consistent style when it is displayed in `git diff`.

The `maint/octave_formatter.py` script is used as the `textconv` filter. It is invoked by `git` to convert the script to a consistent style. 

In order to set it up, you need to add the following to your `.git/config` file:

```ini
[diff "octave"]
        textconv = python3 maint/octave_formatter.py
```

You also need to add the following to your `.gitattributes` file:

```ini
*.m diff=octave
```