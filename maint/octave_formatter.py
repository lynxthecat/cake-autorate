#!/usr/bin/env python3

"""
Modified from matlab-formatter-vscode to add GNU Octave support and other features
which are not available in the original version.

Based on https://github.com/affenwiesel/matlab-formatter-vscode commit 43d7224.

For reference on the differences between GNU Octave and MATLAB, see:
https://en.wikibooks.org/wiki/MATLAB_Programming/Differences_between_Octave_and_MATLAB

Copyright(C) 2019-2021 Benjamin "Mogli" Mann
Copyright(C) 2022 Linuxbckp
Copyright(C) 2024 Rany <rany@riseup.net>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
"""

import argparse
import re
import sys


class Formatter:
    # control sequences
    ctrl_1line = re.compile(
        r"(\s*)(if|while|for|try)(\W\s*\S.*\W)"
        r"((end|endif|endwhile|endfor|end_try_catch);?)"
        r"(\s+\S.*|\s*$)"
    )
    ctrl_1line_dountil = re.compile(r"(^|\s*)(do)(\W\S.*\W)(until)\s*(\W\S.*|\s*$)")
    fcnstart = re.compile(r"(\s*)(function|classdef)\s*(\W\s*\S.*|\s*$)")
    ctrlstart = re.compile(
        r"(\s*)(if|while|for|parfor|try|methods|properties|events|arguments|enumeration|do|spmd)"
        r"\s*(\W\s*\S.*|\s*$)"
    )
    ctrl_ignore = re.compile(r"(\s*)(import|clear|clearvars)(.*$)")
    ctrlstart_2 = re.compile(r"(\s*)(switch)\s*(\W\s*\S.*|\s*$)")
    ctrlcont = re.compile(r"(\s*)(elseif|else|case|otherwise|catch)\s*(\W\s*\S.*|\s*$)")
    ctrlend = re.compile(
        r"(\s*)((end|endfunction|endif|endwhile|endfor|end_try_catch|endswitch|until|endclassdef|"
        r"endmethods|endproperties);?)(\s+\S.*|\s*$)"
    )
    linecomment = re.compile(r"(\s*)[%#].*$")
    ellipsis = re.compile(r".*\.\.\..*$")
    blockcomment_open = re.compile(r"(\s*)%\{\s*$")
    blockcomment_close = re.compile(r"(\s*)%\}\s*$")
    block_close = re.compile(r"\s*[\)\]\}].*$")
    ignore_command = re.compile(r".*formatter\s+ignore\s+(\d*).*$")

    # patterns
    p_string = re.compile(
        r"(.*?[\(\[\{,;=\+\-\*\/\|\&\s]|^)\s*(\'([^\']|\'\')+\')([\)\}\]\+\-\*\/=\|\&,;].*|\s+.*|$)"
    )
    p_string_dq = re.compile(
        r"(.*?[\(\[\{,;=\+\-\*\/\|\&\s]|^)\s*(\"([^\"])*\")([\)\}\]\+\-\*\/=\|\&,;].*|\s+.*|$)"
    )
    p_comment = re.compile(r"(.*\S|^)\s*([%#].*)")
    p_blank = re.compile(r"^\s+$")
    p_num_sc = re.compile(r"(.*?\W|^)\s*(\d+\.?\d*)([eE][+-]?)(\d+)(.*)")
    p_num_R = re.compile(r"(.*?\W|^)\s*(\d+)\s*(\/)\s*(\d+)(.*)")
    p_incr = re.compile(r"(.*?\S|^)\s*(\+|\-)\s*(\+|\-)\s*([\)\]\},;].*|$)")
    p_sign = re.compile(r"(.*?[\(\[\{,;:=\*/\s]|^)\s*(\+|\-)(\w.*)")
    p_colon = re.compile(r"(.*?\S|^)\s*(:)\s*(\S.*|$)")
    p_ellipsis = re.compile(r"(.*?\S|^)\s*(\.\.\.)\s*(\S.*|$)")
    p_op_dot = re.compile(r"(.*?\S|^)\s*(\.)\s*(\+|\-|\*|/|\^)\s*(=)\s*(\S.*|$)")
    p_pow_dot = re.compile(r"(.*?\S|^)\s*(\.)\s*(\^)\s*(\S.*|$)")
    p_pow = re.compile(r"(.*?\S|^)\s*(\^)\s*(\S.*|$)")
    p_op_comb = re.compile(
        r"(.*?\S|^)\s*(\.|\+|\-|\*|\\|/|=|<|>|\||\&|!|~|\^)\s*(<|>|=|\+|\-|\*|/|\&|\|)\s*(\S.*|$)"
    )
    p_not = re.compile(r"(.*?\S|^)\s*(!|~)\s*(\S.*|$)")
    p_op = re.compile(r"(.*?\S|^)\s*(\+|\-|\*|\\|/|=|!|~|<|>|\||\&)\s*(\S.*|$)")
    p_func = re.compile(r"(.*?\w)(\()\s*(\S.*|$)")
    p_open = re.compile(r"(.*?)(\(|\[|\{)\s*(\S.*|$)")
    p_close = re.compile(r"(.*?\S|^)\s*(\)|\]|\})(.*|$)")
    p_comma = re.compile(r"(.*?\S|^)\s*(,|;)\s*(\S.*|$)")
    p_multiws = re.compile(r"(.*?\S|^)(\s{2,})(\S.*|$)")

    def cell_indent(self, line, cell_open: str, cell_close: str, indent):
        # clean line from strings and comments
        pattern = re.compile(rf"(\s*)((\S.*)?)(\{cell_open}.*$)")
        line = self.clean_line_from_strings_and_comments(line)
        opened = line.count(cell_open) - line.count(cell_close)
        if opened > 0:
            m = pattern.match(line)
            n = len(m.group(2))
            indent = (n + 1) if self.matrix_indent else self.iwidth
        elif opened < 0:
            indent = 0
        return (opened, indent)

    def multilinematrix(self, line):
        tmp, self.matrix = self.cell_indent(line, "[", "]", self.matrix)
        return tmp

    def cellarray(self, line):
        tmp, self.cell = self.cell_indent(line, "{", "}", self.cell)
        return tmp

    # indentation
    ilvl = 0
    istep = []
    fstep = []
    iwidth = 0
    matrix = 0
    cell = 0
    isblockcomment = 0
    islinecomment = 0
    longline = 0
    continueline = 0
    separate_blocks = False
    ignore_lines = 0

    def __init__(
        self,
        *,
        indent_width,
        separate_blocks,
        indent_mode,
        operator_sep,
        matrix_indent,
    ):
        self.iwidth = indent_width
        self.separate_blocks = separate_blocks
        self.indent_mode = indent_mode
        self.operator_sep = operator_sep
        self.matrix_indent = matrix_indent

    def clean_line_from_strings_and_comments(self, line):
        split = self.extract_string_comment(line)
        if split:
            return (
                f"{self.clean_line_from_strings_and_comments(split[0])}"
                " "
                f"{self.clean_line_from_strings_and_comments(split[2])}"
            )
        return line

    # divide string into three parts by extracting and formatting certain
    # expressions

    def extract_string_comment(self, part):
        # comment
        m = self.p_comment.match(part)
        if m:
            part = f"{m.group(1)} {m.group(2)}"

        # string
        m = self.p_string.match(part)
        m2 = self.p_string_dq.match(part)
        # choose longer string to avoid extracting subexpressions
        if m2 and (not m or len(m.group(2)) < len(m2.group(2))):
            m = m2
        if m:
            return (m.group(1), m.group(2), m.group(4))

        return 0

    def extract(self, part):
        # whitespace only
        m = self.p_blank.match(part)
        if m:
            return ("", " ", "")

        # string, comment
        string_or_comment = self.extract_string_comment(part)
        if string_or_comment:
            return string_or_comment

        # decimal number (e.g. 5.6E-3)
        m = self.p_num_sc.match(part)
        if m:
            return (
                f"{m.group(1)}{m.group(2)}",
                m.group(3),
                f"{m.group(4)}{m.group(5)}",
            )

        # rational number (e.g. 1/4)
        m = self.p_num_R.match(part)
        if m:
            return (
                f"{m.group(1)}{m.group(2)}",
                m.group(3),
                f"{m.group(4)}{m.group(5)}",
            )

        # incrementor (++ or --)
        m = self.p_incr.match(part)
        if m:
            return (m.group(1), f"{m.group(2)}{m.group(3)}", m.group(4))

        # signum (unary - or +)
        m = self.p_sign.match(part)
        if m:
            return (m.group(1), m.group(2), m.group(3))

        # colon
        m = self.p_colon.match(part)
        if m:
            return (m.group(1), m.group(2), m.group(3))

        # dot-operator-assignment (e.g. .+=)
        m = self.p_op_dot.match(part)
        if m:
            sep = " " if self.operator_sep > 0 else ""
            return (
                f"{m.group(1)}{sep}",
                f"{m.group(2)}{m.group(3)}{m.group(4)}",
                f"{sep}{m.group(5)}",
            )

        # .power (.^)
        m = self.p_pow_dot.match(part)
        if m:
            sep = " " if self.operator_sep > 0.5 else ""
            return (
                f"{m.group(1)}{sep}",
                f"{m.group(2)}{m.group(3)}",
                f"{sep}{m.group(4)}",
            )

        # power (^)
        m = self.p_pow.match(part)
        if m:
            sep = " " if self.operator_sep > 0.5 else ""
            return (f"{m.group(1)}{sep}", m.group(2), f"{sep}{m.group(3)}")

        # combined operator (e.g. +=, .+, etc.)
        m = self.p_op_comb.match(part)
        if m:
            sep = " " if self.operator_sep > 0 else ""
            return (
                f"{m.group(1)}{sep}",
                f"{m.group(2)}{m.group(3)}",
                f"{sep}{m.group(4)}",
            )

        # not (~ or !)
        m = self.p_not.match(part)
        if m:
            return (f"{m.group(1)} ", m.group(2), m.group(3))

        # single operator (e.g. +, -, etc.)
        m = self.p_op.match(part)
        if m:
            sep = " " if self.operator_sep > 0 else ""
            return (f"{m.group(1)}{sep}", m.group(2), f"{sep}{m.group(3)}")

        # function call
        m = self.p_func.match(part)
        if m:
            return (m.group(1), m.group(2), m.group(3))

        # parenthesis open
        m = self.p_open.match(part)
        if m:
            return (m.group(1), m.group(2), m.group(3))

        # parenthesis close
        m = self.p_close.match(part)
        if m:
            return (m.group(1), m.group(2), m.group(3))

        # comma/semicolon
        m = self.p_comma.match(part)
        if m:
            return (m.group(1), m.group(2), f" {m.group(3)}")

        # ellipsis
        m = self.p_ellipsis.match(part)
        if m:
            return (f"{m.group(1)} ", m.group(2), f" {m.group(3)}")

        # multiple whitespace
        m = self.p_multiws.match(part)
        if m:
            return (m.group(1), " ", m.group(3))

        return 0

    # recursively format string
    def format(self, part):
        m = self.extract(part)
        if m:
            return f"{self.format(m[0])}{m[1]}{self.format(m[2])}"
        return part

    # compute indentation
    def indent(self, add_space=0):
        return ((self.ilvl + self.continueline) * self.iwidth + add_space) * " "

    # take care of indentation and call format(line)
    def format_line(self, line):

        if self.ignore_lines > 0:
            self.ignore_lines -= 1
            return (0, f"{self.indent()}{line.strip()}")

        # determine if linecomment
        if re.match(self.linecomment, line):
            self.islinecomment = 2
        else:
            # we also need to track whether the previous line was a commment
            self.islinecomment = max(0, self.islinecomment - 1)

        # determine if blockcomment
        if re.match(self.blockcomment_open, line):
            self.isblockcomment = float("inf")
        elif re.match(self.blockcomment_close, line):
            self.isblockcomment = 1
        else:
            self.isblockcomment = max(0, self.isblockcomment - 1)

        # find ellipsis
        stripped_line = self.clean_line_from_strings_and_comments(line)
        ellipsis_in_comment = self.islinecomment == 2 or self.isblockcomment
        if re.match(self.block_close, stripped_line) or ellipsis_in_comment:
            self.continueline = 0
        else:
            self.continueline = self.longline
        if re.match(self.ellipsis, stripped_line) and not ellipsis_in_comment:
            self.longline = 1
        else:
            self.longline = 0

        # find comments
        if self.isblockcomment:
            return (0, line.rstrip())  # don't modify indentation in block comments
        if self.islinecomment == 2:
            # check for ignore statement
            m = re.match(self.ignore_command, line)
            if m:
                if m.group(1) and int(m.group(1)) > 1:
                    self.ignore_lines = int(m.group(1))
                else:
                    self.ignore_lines = 1
            return (0, f"{self.indent()}{line.strip()}")

        # find imports, clear, etc.
        m = re.match(self.ctrl_ignore, line)
        if m:
            return (0, f"{self.indent()}{line.strip()}")

        # find matrices
        tmp = self.matrix
        if self.multilinematrix(line) or tmp:
            return (0, f"{self.indent(tmp)}{self.format(line).strip()}")

        # find cell arrays
        tmp = self.cell
        if self.cellarray(line) or tmp:
            return (0, f"{self.indent(tmp)}{self.format(line).strip()}")

        # find control structures
        m = re.match(self.ctrl_1line, line)
        if m:
            return (
                0,
                f"{self.indent()}{m.group(2)} {self.format(m.group(3)).strip()} "
                f"{m.group(4)} {self.format(m.group(6)).strip()}",
            )

        m = re.match(self.fcnstart, line)
        if m:
            offset = self.indent_mode
            self.fstep.append(1)
            if self.indent_mode == -1:
                offset = int(len(self.fstep) > 1)
            return (
                offset,
                f"{self.indent()}{m.group(2)} {self.format(m.group(3)).strip()}",
            )

        m = re.match(self.ctrl_1line_dountil, line)
        if m:
            return (
                0,
                f"{self.indent()}{m.group(2)} {self.format(m.group(3)).strip()} "
                f"{m.group(4)} {m.group(5)}",
            )

        m = re.match(self.ctrl_1line_dountil, line)
        if m:
            return (
                0,
                f"{self.indent()}{m.group(2)} {self.format(m.group(3)).strip()} "
                f"{m.group(4)} {m.group(5)}",
            )

        m = re.match(self.ctrlstart, line)
        if m:
            self.istep.append(1)
            return (
                1,
                f"{self.indent()}{m.group(2)} {self.format(m.group(3)).strip()}",
            )

        m = re.match(self.ctrlstart_2, line)
        if m:
            self.istep.append(2)
            return (
                2,
                f"{self.indent()}{m.group(2)} {self.format(m.group(3)).strip()}",
            )

        m = re.match(self.ctrlcont, line)
        if m:
            return (
                0,
                f"{self.indent(-self.iwidth)}{m.group(2)} {self.format(m.group(3)).strip()}",
            )

        m = re.match(self.ctrlend, line)
        if m:
            if len(self.istep) > 0:
                step = self.istep.pop()
            elif len(self.fstep) > 0:
                step = self.fstep.pop()
            else:
                print("There are more end-statements than blocks!", file=sys.stderr)
                step = 0
            return (
                -step,
                f"{self.indent(-step * self.iwidth)}{m.group(2)} "
                f"{self.format(m.group(4)).strip()}",
            )

        return (0, f"{self.indent()}{self.format(line).strip()}")

    # format file from line 'start' to line 'end'
    def format_file(self, *, filename, start, end, inplace):
        # read lines from file
        wlines = rlines = []

        with (
            sys.stdin if filename == "-" else open(filename, "r", encoding="UTF-8")
        ) as f:
            rlines = f.readlines()[start - 1 : end]

        # take care of empty input
        if not rlines:
            rlines = [""]

        # get initial indent lvl
        p = r"(\s*)(.*)"
        m = re.match(p, rlines[0])
        if m:
            self.ilvl = len(m.group(1)) // self.iwidth
            rlines[0] = m.group(2)

        blank = True
        for line in rlines:
            # remove additional newlines
            if re.match(r"^\s*$", line):
                if not blank:
                    blank = True
                    wlines.append("")
                continue

            # format line
            (offset, line) = self.format_line(line)

            # adjust indent lvl
            self.ilvl = max(0, self.ilvl + offset)

            # add newline before block
            if (
                self.separate_blocks
                and offset > 0
                and not blank
                and not self.islinecomment
            ):
                wlines.append("")

            # add formatted line
            wlines.append(line.rstrip())

            # add newline after block
            blank = self.separate_blocks and offset < 0
            if blank:
                wlines.append("")

        # remove last line if blank
        while wlines and not wlines[-1]:
            wlines.pop()

        # take care of empty output
        if not wlines:
            wlines = [""]

        # write output
        if inplace:
            if filename == "-":
                print("Cannot write inplace to stdin!", file=sys.stderr)
                return

            if not (start == 1 and end is None):
                print("Cannot write inplace to a slice of a file!", file=sys.stderr)
                return

            with open(filename, "w", encoding="UTF-8") as f:
                for line in wlines:
                    f.write(f"{line}\n")
        else:
            for line in wlines:
                print(line)


def main():
    parser = argparse.ArgumentParser(description="MATLAB formatter")
    parser.add_argument("filename", help="input file")
    parser.add_argument("--start-line", type=int, default=1, help="start line")
    parser.add_argument("--end-line", type=int, help="end line")
    parser.add_argument("--indent-width", type=int, default=4, help="indent width")
    parser.add_argument(
        "--separate-blocks", action="store_true", help="separate blocks"
    )
    parser.add_argument(
        "--indent-mode",
        choices=["all_functions", "only_nested_functions", "classic"],
        default="all_functions",
        help="indent mode",
    )
    parser.add_argument(
        "--add-space",
        choices=["all_operators", "exclude_pow", "no_spaces"],
        default="exclude_pow",
        help="add space",
    )
    parser.add_argument(
        "--matrix-indent",
        choices=["aligned", "simple"],
        default="aligned",
        help="matrix indentation",
    )
    parser.add_argument("--inplace", action="store_true", help="modify file in place")
    args = parser.parse_args()

    indent_modes = {"all_functions": 1, "only_nested_functions": -1, "classic": 0}
    operator_spaces = {"all_operators": 1, "exclude_pow": 0.5, "no_spaces": 0}
    matrix_indentation = {"aligned": 1, "simple": 0}

    formatter = Formatter(
        indent_width=args.indent_width,
        separate_blocks=args.separate_blocks,
        indent_mode=indent_modes.get(args.indent_mode, indent_modes["all_functions"]),
        operator_sep=operator_spaces.get(
            args.add_space, operator_spaces["exclude_pow"]
        ),
        matrix_indent=matrix_indentation.get(
            args.matrix_indent, matrix_indentation["aligned"]
        ),
    )

    formatter.format_file(
        filename=args.filename,
        start=args.start_line,
        end=args.end_line,
        inplace=args.inplace,
    )


if __name__ == "__main__":
    main()
