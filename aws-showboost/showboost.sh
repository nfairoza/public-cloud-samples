#!/bin/bash
#
# showboost	Show C0 cycle rate (turbo boost). MSR specific (updated for AMD)
#
# This was written for use in a VM guest (AWS EC2).
#
# USAGE: showboost [-C CPU] [interval [count]]
#
# This uses the CPU Model Specific Registers to read the turbo boost ratios and
# CPU cycles. The way the MSR is read is processor specific. If you want to run
# this on other CPU types, the MSR definitions section will need editing.
#
# FIELDS:
#
# - Base CPU MHz: The processor's base frequency. Not boosted in any way.
# - Set CPU MHz: The current CPU frequency requested by the kernel's CPU
# 		 frequency scaler.
# - Turbo MHz(s): The range of possible turbo boost steps.
# - Turbo Ratios: Turbo boost steps, as a percent ratio over base.
#
# Note that the kernel can set a CPU frequency in the turbo boost range, unless
# /sys/devices/system/cpu/intel_pstate/no_turbo is set to 1.
#
# SEE ALSO: turbostat
#
# COPYRIGHT: Copyright (c) 2014 Brendan Gregg.
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License
#  as published by the Free Software Foundation; either version 2
#  of the License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software Foundation,
#  Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
#  (http://www.gnu.org/copyleft/gpl.html)
#
# 12-Sep-2014   Brendan Gregg   Created this.
# 02-Mar-2018      "      "     Changed base MHz source to fix an MHz bug.
# 09-Sep-2023	Lewis Carroll	Modified for AMD Zen4

### MSR definitions
IA32_MPERF=0xe7
IA32_APERF=0xe8
MSR_TURBO_RATIO_LIMIT=0x1ad
MSR_TURBO_RATIO_LIMIT1=0x1ae
MSR_AMD_PSTATE=0x10063		# Bits 2:0 indicate current P-state, index to next register
MSR_AMD_P0=0x10064		# Bits 7:0 indicate frequency (scalar = 125 MHz) CHECK!

### sanity check
family=$(awk '/cpu family/ { print $NF; exit }' /proc/cpuinfo)
if (( family != 6 && family != 25 )); then
	echo >&2 "WARNING: CPU family $family not recognized (not Intel or AMD?):"
	head >&2 /proc/cpuinfo
	echo >&2 "WARNING: continuining, but data is probably wrong."
	echo >&2 "WARNING: edit this script to use the correct MSRs."
fi

### options
function usage {
	echo >&2 "USAGE: showboost [-C CPU] [interval [count]]"
	exit
}

opt_cpu=0; cpu=0

while getopts C:h opt
do
	case $opt in
	C)	opt_cpu=1; cpu=$OPTARG ;;
	h|?)	usage ;;
	esac
done
shift $(( $OPTIND - 1 ))
interval=${1:-1}
count=${2:-999999999}		# default semi-infinite seconds

if [[ "$USER" != "root" ]]; then
	echo >&2 "ERROR: needs root access. Exiting."
	exit 1
fi

if ! /sbin/modprobe msr; then
	echo >&2 "ERROR: modprobe msr. Missing msr-tools package? Exiting."
	exit 1
fi

#
# Intel Turbo Frequency MSR Notes
#
# This is according to the Intel 64 and IA-32 Architectures Software Developer's
# Manual, July 2017. The following "undefined" MSRs mean they are not defined
# in that manual.
#
# Atom
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-63:56
#	1AE	undefined
# Goldmont
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-63:56
#	1AE	MSR_TURBO_GROUP_CORECNT	7:0-63:56
# Nehalem
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-31:24
#	1AE	undefined
# 5500, 3400
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-31:24
#	1AE	undefined
# 7500
#	1AD	reserved (#UD)
#	1AE	undefined
# Westmere
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-47:40
#	1AE	undefined
# E7
#	1AD	reserved (#UD)
#	1AE	undefined
# Sandy Bridge
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-31:24
#	1AE	undefined
# E5
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-63:56
#	1AE	undefined
# Ivy Bridge-E
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-31:24
#	1AE	undefined
# E7 v2
#	1AD
#	1AE	MSR_TURBO_RATIO_LIMIT1	7:0-55:48 (bit 63 is an MSR selector)
# Haswell
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-31:24
#	1AE	undefined
# E5 v3
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-63:56
#	1AE	MSR_TURBO_RATIO_LIMIT1	7:0-63:56
#	1AF	MSR_TURBO_RATIO_LIMIT2	7:0-15:8 (bit 63 is an MSR selector)
# M
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-47:40
#	1AE	undefined
# D, E5 v4
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-63:56
#	1AE	MSR_TURBO_RATIO_LIMIT1	7:0-63:56
# additional D with 06_46, D with 06_4F
#	1AC	MSR_TURBO_RATIO_LIMIT3	(bit 63 selector)
# Skylake, Kaby Lake
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-31:24
#	1AE	undefined
# 06_55
#	1AD	MSR_TURBO_RATIO_LIMIT	7:0-63:56
#	1AE	MSR_TURBO_RATIO_LIMIT_CORES	7:0-63:56
# Phi with 06_57, Phy with 06_85
#	1AD	MSR_TURBO_RATIO_LIMIT	completely different scheme
#
# This lacks much consistency, and the only accurate solution is to deal with
# each architecture separately. To start with, we'll need a complete lookup
# table of DisplayFamily_DisplayModel (which can be read from /proc/cpuinfo)
# to architecture name. I've never seen a complete table. Pat posted a 91
# entry table on
# https://software.intel.com/en-us/articles/intel-architecture-and-processor-identification-with-cpuid-model-and-family-numbers
# however, that's already out of date (it was posted in 2015).
#
# As a workaround until I have all the information to complete this (which may
# never happen), I'll use the following approach:
#
# - Sweep the 0:7-63:56 range of both 1AD and 1AE, on the assumption that each
#   byte is a turbo frequency.
# - If that byte is zero, discard it.
# - If that byte is less than the base frequency, discard that whole MSR
#   (as it's likely a core count).
# - Ignore the MSR selector bit for now.
# - Ignore Phy for now (the MSR will be discarded, or print obvious junk)
# - Ignore 1AF for now.
# 
# This approach should work for most systems.
#

### main

# Intel support
if (( family == 6 )); then
	# Fetch the base CPU MHz from the model string. Yes, this is a hack. The proper
	# way to do this is via MSR_PLATFORM_INFO or CPUID 0x15. Both are architecture
	# dependent. When I need to, I'll switch to them.
	base_mhz=$(awk '
		/^model name.*GHz$/ { sub(/GHz/, "", $NF); printf("%d", $NF * 1000); exit; }
		/^model name.*MHz/ { sub(/MHz/, "", $NF); printf("%d", $NF); exit; }' /proc/cpuinfo)
	if (( base_mhz == 0 )); then
		echo "ERROR: Can't find base MHz from /proc/cpuinfo model name. Exiting."
		# if this happens, switch to MSR_PLATFORM_INFO or CPUID
		exit 1
	fi
	set_mhz=$(awk '/^cpu MHz/ { print $NF; exit }' /proc/cpuinfo)
	set_mhz=${set_mhz%.*}
	turbos=""
	ratios=""
	last=0
	for msr in $MSR_TURBO_RATIO_LIMIT1 $MSR_TURBO_RATIO_LIMIT; do
		tmpturbos=""; tmpratios=""
		for mask in 63:56 55:48 47:40 39:32 31:24 23:16 15:8 7:0; do
			turbo=$(rdmsr $msr -f $mask -d)
			(( turbo == 0 )) && continue
			(( turbo *= 100 ))
			if (( turbo < base_mhz )); then
				# core count or special MSR; abort
				tmpturbos=""; tmpratios=""
				break
			fi
			if (( last != turbo )); then
				tmpturbos="$tmpturbos $turbo"
				(( ratio = turbo * 100 / base_mhz ))
				tmpratios="$tmpratios $ratio%"
			fi
			last=$turbo
		done
		turbos="$turbos $tmpturbos"
		ratios="$ratios $tmpratios"
	done

# AMD support
elif (( family == 25 )); then
	# Hacks for now - Base (P0) frequency and FMAX for AWS 9R14
	base_mhz="2600"
	turbos="3700"
	set_mhz=$(awk '/^cpu MHz/ { print $NF; exit }' /proc/cpuinfo)
	set_mhz=${set_mhz%.*}
fi


echo "Base CPU MHz :" $base_mhz
echo "Set CPU MHz  :" $set_mhz
echo "Turbo MHz(s) :" $turbos
echo "Turbo Ratios :" $ratios
echo "CPU $cpu summary every $interval seconds..."
echo

printf "%-10s %-12s %-12s %6s %6s %6s\n" "TIME" "C0_MCYC" "C0_ACYC" "UTIL" \
    "RATIO" "MHz"

lines=0
while :; do
	t=$(printf "%(%H:%M:%S)T" -1)
	m=$(rdmsr -p$cpu $IA32_MPERF -d)
	a=$(rdmsr -p$cpu $IA32_APERF -d)
	(( dm = m - lm ))
	(( da = a - la ))
	(( ratio = 100 * da / dm ))
	(( max_mhz = base_mhz * da / dm ))
	(( util = dm * 100 / (base_mhz * 1000000 * interval) ))
	if (( lm > 0 )); then
		printf "%-10s %-12d %-12d %5d%% %5d%% %6d\n" $t $dm $da $util \
		    $ratio $max_mhz
	fi
	lm=$m
	la=$a
	(( lines++ ))
	(( lines > count )) && break
	sleep $interval
done
