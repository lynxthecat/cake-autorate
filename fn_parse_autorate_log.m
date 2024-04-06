function [ ] = fn_parse_autorate_log( log_FQN, plot_FQN, x_range_sec, selected_reflector_subset )
	% This program is free software; you can redistribute it and/or modify
	% it under the terms of the GNU General Public License version 2 as
	% published by the Free Software Foundation.
	%
	%       Copyright (C) 2022 Sebastian Moeller

	% HOWTO:
	% you need to install octave (https://octave.org)
	% then navigate to the directory containing fn_parse_autorate_log.m and either:
	% run 'octave --gui' in a terminal and open the file and run it (recommended if you want/need to edit values)
	% or run 'octave ./fn_parse_autorate_log.m' from the terminal
	% the following will work on the console without requiring interaction
	% octave -qf --eval 'fn_parse_autorate_log("./SCRATCH/cake-autorate.log.20221001_1724_RRUL_fast.com.log", "./outpug.tif", [10, 500], {"1.1.1.1"})'
	% symbolically: octave -qf --eval 'fn_parse_autorate_log("path/to/the/log.file", "path/to/the/output/plot.format", [starttime endtime], {selected_reflector_subset})'
	%	supported formats for the optional second argument: pdf, png, tif.
	% 	the optional third argument is the range to plot in seconds after log file start
	%	the fourth argument is a list of reflector IDs, only samples from any of the listed reflectors will be plotted, use [] to select all reflectors
	% by default the code will open a file selection dialog which should be used to select a CAKE-autorate log file.

	% TODO:
	%	add CDF plots for RTTs/OWDs per reflector for low and high achieved rate states
	%		the goal is to show low versus high load delay CDFs, but we do not really know about the relative load so
	%		this will only be a heuristic, albeit a useful one, hopefully.
	%		- add OWD/RTT plots for both load directions
	%		- report 95 and 99%-iles of lowest load conditions as output to help selecting delay thresholds


	%gts = available_graphics_toolkits()
	%qt_available = any(strcmp(gts, 'qt'))
	%available_graphics_toolkits
	%graphics_toolkit("gnuplot");

	%if ~(isoctave)
	dbstop if error;
	%end

	timestamps.(mfilename).start = tic;
	fq_mfilename = mfilename('fullpath');
	mfilepath = fileparts(fq_mfilename);

	disp(['INFO: ', mfilepath]);

	% for debugging anything else than '' or 'load_existing' will force the file to be reparsed
	parse_command_string = ''; % load_existing or reload


	% specific cofiguration options for different plot types
	CDF.LowLoad_threshold_percent = 20;		% max load% for low load condition
	CDF.HighLoad_threshold_percent = 80;	% min load% for high load condition
	CDF.calc_range_ms = [0, 1000];	% what range to calculate the CDFs over? We can always reduce the plotted range later, see cumulative_range_percent
	CDF.step_size_ms = 0.005;	% we will see this as quantization in the plots...
	CDF.cumulative_range_percent = [0.001, 97.5];	% which range to show for CDFs (taken from the fastest/slowest reflector respectively)
	% PDFs are mostly like CDFs except for the step_size
	PDF = CDF;
	PDF.step_size_ms = 0.2;	% these histograms need to be coarser than the PDFs or we see odd PDFs
	PDF.cumulative_range_percent = [0.001, 90.0];	% which range to show for PDFs (taken from the fastest/slowest reflector respectively)

	% add all defined plots that should be created and saved
	plot_list = {'rawCDFs', 'deltaCDFs', 'timecourse'}; % 'rawCDFs', 'deltaCDFs', 'rawPDFs', 'deltaPDFs', 'timecourse' % PDFs are currently broken

	try

		figure_visibility_string = 'on';
		if ~exist('log_FQN', 'var') || isempty(log_FQN)
			log_FQN = [];
			% for debugging
			%log_FQN = "./SCRATCH/cake-autorate_2022-10-29_23_29_45.log";
		else
			disp(['INFO: Processing log file: ', log_FQN]);
			figure_visibility_string = 'off';
		endif
		figure_opts.figure_visibility_string = figure_visibility_string;

		if ~exist('plot_FQN', 'var') || isempty(plot_FQN)
			plot_FQN = [];
		else
			disp(['INFO: Trying to save plot as: ', plot_FQN]);
			[plot_path, plot_name, plot_ext] = fileparts(plot_FQN);
		endif

		% load the data file
		[autorate_log, log_FQN] = fn_parse_autorate_logfile(log_FQN, parse_command_string);
		% dissect the fully qualified name
		[log_dir, log_name, log_ext ] = fileparts(log_FQN);


		% find the relevant number of samples and whether we have LOAD records to begin with
		if isfield(autorate_log, 'LOAD') && isfield(autorate_log.LOAD, 'LISTS') && isfield(autorate_log.LOAD.LISTS, 'RECORD_TYPE') && ~isempty(autorate_log.LOAD.LISTS.RECORD_TYPE)
			n_LOAD_samples = length(autorate_log.LOAD.LISTS.RECORD_TYPE);
		else
			n_LOAD_samples = 0;
		endif

		% check whether we did successfully load some data, other wise bail out:
		if ~isfield(autorate_log, 'DATA') || ~isfield(autorate_log.DATA, 'LISTS') || ~isfield(autorate_log.DATA.LISTS, 'RECORD_TYPE') || isempty(autorate_log.DATA.LISTS.RECORD_TYPE)
			if (n_LOAD_samples == 0)
				disp('WARNING: No valid data found, nothing to plot? Exiting...');
				return
			endif
			n_DATA_samples = 0;
			autorate_log.DATA.LISTS = [];
		else
			n_DATA_samples = length(autorate_log.DATA.LISTS.RECORD_TYPE);
		endif


		% find the smallest and largest (or first and last) DATA or LOAD timestamps
		if (n_DATA_samples > 0)
			first_sample_timestamp = autorate_log.DATA.LISTS.PROC_TIME_US(1);
			last_sample_timestamp = autorate_log.DATA.LISTS.PROC_TIME_US(end);
		else
			first_sample_timestamp = 60*60*24*365*1000; % make this larger than any realistic unix epoch in seconds is going to be...
			last_sample_timestamp = 0; % we take the maximum, so will override this
		endif

		if (n_LOAD_samples > 0)
			first_sample_timestamp = min([first_sample_timestamp, autorate_log.LOAD.LISTS.PROC_TIME_US(1)]);
			last_sample_timestamp = max([last_sample_timestamp, autorate_log.LOAD.LISTS.PROC_TIME_US(end-1)]);
		endif

		% select the sample range to display:
		% 0 denotes the start, the second value the maximum time to display
		% if the end index is too large we clip to max timestamp
		% [] denotes all samples...
		% can be passed via argument, default ot the full range
		if ~exist('x_range_sec', 'var') || isempty(x_range_sec)
			% use this to change the values if not calling this as a function
			% select the time range to display in seconds since first sample
			% with different time axis for DATA and LOAD, simple indices are not appropriate anymore
			x_range_sec = [];
			%x_range_sec = [900 1000];
		else
			%x_range_sec = [];
			if ~isempty(x_range_sec);
				disp(['INFO: requested x_range_sec: ', num2str(x_range_sec)]);
			endif
		endif
		% clean up the time range somewhat
		[x_range_sec, do_return] = fn_sanitize_x_range_sec(x_range_sec, first_sample_timestamp, last_sample_timestamp);
		if (do_return)
			return
		endif

		% now, get the data range indices for the selected record types
		if (n_DATA_samples > 0)
			x_range.DATA = fn_get_range_indices_from_range_timestamps((x_range_sec + first_sample_timestamp), autorate_log.DATA.LISTS.PROC_TIME_US);
			[x_range.DATA, do_return] = fn_sanitize_x_range(x_range.DATA, n_DATA_samples);
		endif
		if (n_LOAD_samples > 0)
			x_range.LOAD = fn_get_range_indices_from_range_timestamps((x_range_sec + first_sample_timestamp), autorate_log.LOAD.LISTS.PROC_TIME_US);
			[x_range.LOAD, do_return] = fn_sanitize_x_range(x_range.LOAD, n_LOAD_samples);
			if (n_DATA_samples == 0)
				x_range.DATA = x_range.LOAD; % needed for plot nameing...
			endif
		end
		if (do_return)
			return
		endif

		% allow to restrict the plot to a subset of the reflectors.
		if ~exist('selected_reflector_subset', 'var') || isempty(selected_reflector_subset)
			selected_reflector_subset = {}; % default to all
			%selected_reflector_subset = {"1.1.1.1"};
			%selected_reflector_subset = {"1.1.1.1", "1.0.0.1"};
		else
			% take from input argument
			%selected_reflector_subset = [];
			disp(['INFO: requested selected_reflector_subset: ', selected_reflector_subset]);
		endif
		reflector_string = '';
		if ~isempty(selected_reflector_subset)
			reflector_string = '.R';
			for i_reflector = 1 : length(selected_reflector_subset)
				reflector_string = [reflector_string, '_', selected_reflector_subset{i_reflector}];
			endfor
			reflector_string(end+1) = '.';
		endif

		% new reflectors get initialized with a very high beaseline prior (which quickly gets adjusted to a better estimate)
		% resulting in very high baseline values that cause poor autoscaling of the delay y-axis
		% this parameter will control the minimum delay sample sequence number to use, allowing to
		% ignore the early intialisation phase with small sequence numbers
		% this issue only affects delay data, so this will be ignored for the rates
		% set to 0 to show all delay samples,
		min_sequence_number = 1;

		align_rate_and_delay_zeros = 1; % so that delay and rate 0s are aligned
		output_format_extension = '.png'; % '.pdf', '.png', '.tif', '.ps
		line_width = 1.0;
		figure_opts.line_width = line_width;
		figure_opts.output_format_extension = output_format_extension;
		% a few outlier will make the delay plots unreadable, if this is not empty [],
		% use this factor on max(ADJ_DELAY_THR) to scale the delay axis
		% this is done before align_rate_and_delay_zeros is applied.
		scale_delay_axis_by_ADJ_DELAY_THR_factor = 2.0;
		% if the following is set make sure we also scale to the actual data
		% we calculate both y-axis scales and take the maximum if both are requested
		scale_delay_axis_by_OWD_DELTA_QUANTILE_factor = 5.0; % ignore if empty []
		OWD_DELTA_QUANTILE_pct = 99.0; % what upper quantile to use for scaling, 100 is max value



		% set up the plots
		rates.DATA.fields_to_plot_list = {'CAKE_DL_RATE_KBPS', 'CAKE_UL_RATE_KBPS', 'DL_ACHIEVED_RATE_KBPS', 'UL_ACHIEVED_RATE_KBPS'};
		rates.DATA.color_list = {[241,182,218]/254, [184,225,134]/254, [208,28,139]/254, [77,172,38]/254};
		rates.DATA.linestyle_list = {'-', '-', '-', '-'};
		rates.DATA.sign_list = {1, -1, 1, -1};	% define the sign of a given data series, allows flipping a set into the negative range
		rates.DATA.scale_factor = 1/1000;		% conversion factor from Kbps to Mbps

		% based on LOAD records replace the older 'DL_ACHIEVED_RATE_KBPS', 'UL_ACHIEVED_RATE_KBPS' fields from DATA
		% this will allow to plot data from sleep epochs, at the cost of some x_value trickery.
		rates.LOAD.scale_factor = 1/1000;		% conversion factor from µs to ms
		rates.LOAD.fields_to_plot_list = {};
		rates.LOAD.color_list = {};
		rates.LOAD.linestyle_list = {};
		rates.LOAD.sign_list = {};
		if (n_LOAD_samples > 0)
			%			% these two should only be shown during sleep periods?
			%			% otherwise LOAD and higher resolution DATA plots will "overlap'
			%			if isfield(autorate_log.DATA.LISTS, 'CAKE_DL_RATE_KBPS')
			%				rates.LOAD.fields_to_plot_list{end+1} = 'CAKE_DL_RATE_KBPS';
			%				rates.LOAD.color_list{end+1} = [241,182,218]/254;
			%				rates.LOAD.linestyle_list{end+1} = '-';
			%				rates.LOAD.sign_list{end+1} = 1;
			%			end
			%			if isfield(autorate_log.DATA.LISTS, 'CAKE_UL_RATE_KBPS')
			%				rates.LOAD.fields_to_plot_list{end+1} = 'CAKE_UL_RATE_KBPS';
			%				rates.LOAD.color_list{end+1} = [184,225,134]/254;
			%				rates.LOAD.linestyle_list{end+1} = '-';
			%				rates.LOAD.sign_list{end+1} = -1;
			%			end

			% these can be replaced...
			if isfield(autorate_log.LOAD.LISTS, 'DL_ACHIEVED_RATE_KBPS')
				rates.LOAD.fields_to_plot_list{end+1} = 'DL_ACHIEVED_RATE_KBPS';
				rates.LOAD.color_list{end+1} = [208,28,139]/254;
				rates.LOAD.linestyle_list{end+1} = '-';
				rates.LOAD.sign_list{end+1} = 1;
				rate_DATA_idx = find(ismember(rates.DATA.fields_to_plot_list, {'DL_ACHIEVED_RATE_KBPS'}));
				rates.DATA.fields_to_plot_list(rate_DATA_idx) = [];
				rates.DATA.color_list(rate_DATA_idx) = [];
				rates.DATA.linestyle_list(rate_DATA_idx) = [];
				rates.DATA.sign_list(rate_DATA_idx) = [];
			end
      if isfield(autorate_log.LOAD.LISTS, 'UL_ACHIEVED_RATE_KBPS')
				rates.LOAD.fields_to_plot_list{end+1} = 'UL_ACHIEVED_RATE_KBPS';
				rates.LOAD.color_list{end+1} = [77,172,38]/254;
				rates.LOAD.linestyle_list{end+1} = '-';
				rates.LOAD.sign_list{end+1} = -1;
				rate_DATA_idx = find(ismember(rates.DATA.fields_to_plot_list, {'UL_ACHIEVED_RATE_KBPS'}));
				rates.DATA.fields_to_plot_list(rate_DATA_idx) = [];
				rates.DATA.color_list(rate_DATA_idx) = [];
				rates.DATA.linestyle_list(rate_DATA_idx) = [];
				rates.DATA.sign_list(rate_DATA_idx) = [];
			end
		endif

		% create the latency data ollection and configuration
		delays.DATA.scale_factor = 1/1000;		% conversion factor from µs to ms
		delays.DATA.fields_to_plot_list = {};
		delays.DATA.color_list = {};
		delays.DATA.linestyle_list = {};
		delays.DATA.sign_list = {};

		% colors from https://colorbrewer2.org/#type=diverging&scheme=BrBG&n=8
		% re-order the following to assign depth order in plot...
		if isfield(autorate_log.DATA.LISTS, 'DL_OWD_BASELINE')
			delays.DATA.fields_to_plot_list{end+1} = 'DL_OWD_BASELINE';
			delays.DATA.color_list{end+1} = [246, 232, 195]/254;
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = 1;
		end

		if isfield(autorate_log.DATA.LISTS, 'UL_OWD_BASELINE')
			delays.DATA.fields_to_plot_list{end+1} = 'UL_OWD_BASELINE';
			delays.DATA.color_list{end+1} = [199, 234, 229]/254;
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = -1;
		end

		if isfield(autorate_log.DATA.LISTS, 'DL_OWD_US')
			delays.DATA.fields_to_plot_list{end+1} = 'DL_OWD_US';
			delays.DATA.color_list{end+1} = [223, 194, 125]/254;
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = 1;
		end

		if isfield(autorate_log.DATA.LISTS, 'UL_OWD_US')
			delays.DATA.fields_to_plot_list{end+1} = 'UL_OWD_US';
			delays.DATA.color_list{end+1} = [128, 205, 193]/254;
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = -1;
		end

		if isfield(autorate_log.DATA.LISTS, 'DL_OWD_DELTA_US')
			delays.DATA.fields_to_plot_list{end+1} = 'DL_OWD_DELTA_US';
			delays.DATA.color_list{end+1} = [191, 129, 45]/254;
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = 1;
		end

		if isfield(autorate_log.DATA.LISTS, 'UL_OWD_DELTA_US')
			delays.DATA.fields_to_plot_list{end+1} = 'UL_OWD_DELTA_US';
			delays.DATA.color_list{end+1} = [53, 151, 143]/254;
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = -1;
		end


		if isfield(autorate_log.DATA.LISTS, 'DL_AVG_OWD_DELTA_US')
			delays.DATA.fields_to_plot_list{end+1} = 'DL_AVG_OWD_DELTA_US';
			delays.DATA.color_list{end+1} = [0.33, 0 , 0]; %[191, 129, 45]/254;
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = 1;
		end

		if isfield(autorate_log.DATA.LISTS, 'UL_AVG_OWD_DELTA_US')
			delays.DATA.fields_to_plot_list{end+1} = 'UL_AVG_OWD_DELTA_US';
			delays.DATA.color_list{end+1} = [0.33, 0 , 0]; %[53, 151, 143]/254;
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = -1;
		end



		% to allow old (single ADJ_DELAY_THR) and new log files
		if isfield(autorate_log.DATA.LISTS, 'DL_ADJ_AVG_OWD_DELTA_THR_US')
			delays.DATA.fields_to_plot_list{end +1} = 'DL_ADJ_AVG_OWD_DELTA_THR_US';
			delays.DATA.color_list{end+1} = [0.5, 0.0, 0.0];
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = 1;
		endif


		% to allow old (single ADJ_DELAY_THR) and new log files
		if isfield(autorate_log.DATA.LISTS, 'UL_ADJ_AVG_OWD_DELTA_THR_US')
			delays.DATA.fields_to_plot_list{end+1} = 'UL_ADJ_AVG_OWD_DELTA_THR_US';
			delays.DATA.color_list{end+1} = [0.5, 0.0, 0.0];
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = -1;
		endif




		% to allow old (single ADJ_DELAY_THR) and new log files
		if isfield(autorate_log.DATA.LISTS, 'ADJ_DELAY_THR') || isfield(autorate_log.DATA.LISTS, 'DL_ADJ_DELAY_THR')
			if isfield(autorate_log.DATA.LISTS, 'DL_ADJ_DELAY_THR')
				delays.DATA.fields_to_plot_list{end +1} = 'DL_ADJ_DELAY_THR';
			elseif isfield(autorate_log.DATA.LISTS, 'ADJ_DELAY_THR')
				delays.DATA.fields_to_plot_list{end+1} = 'ADJ_DELAY_THR';
			endif
			delays.DATA.color_list{end+1} = [1.0, 0.0, 0.0];
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = 1;
		endif


		% to allow old (single ADJ_DELAY_THR) and new log files
		if isfield(autorate_log.DATA.LISTS, 'ADJ_DELAY_THR') || isfield(autorate_log.DATA.LISTS, 'UL_ADJ_DELAY_THR')
			if isfield(autorate_log.DATA.LISTS, 'UL_ADJ_DELAY_THR')
				delays.DATA.fields_to_plot_list{end+1} = 'UL_ADJ_DELAY_THR';
			elseif isfield(autorate_log.DATA.LISTS, 'ADJ_DELAY_THR')
				delays.DATA.fields_to_plot_list{end+1} = 'ADJ_DELAY_THR';
			endif
			delays.DATA.color_list{end+1} = [1.0, 0.0, 0.0];
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = -1;
		endif

		% if exist, plot the delta EWMA
		if isfield(autorate_log.DATA.LISTS, 'DL_OWD_DELTA_EWMA_US')
			delays.DATA.fields_to_plot_list{end+1} = 'DL_OWD_DELTA_EWMA_US';
			delays.DATA.color_list{end+1} = [140, 81, 10]/254;
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = 1;
		end

		if isfield(autorate_log.DATA.LISTS, 'UL_OWD_DELTA_EWMA_US')
			delays.DATA.fields_to_plot_list{end+1} = 'UL_OWD_DELTA_EWMA_US';
			delays.DATA.color_list{end+1} = [1, 102, 94]/254;
			delays.DATA.linestyle_list{end+1} = '-';
			delays.DATA.sign_list{end+1} = -1;
		end


		% get x_vector data and which indices to display for each record type
		x_vec.DATA = (1:1:n_DATA_samples);
		if ~isempty(x_vec.DATA)
			DATA_rates_x_idx = (x_range.DATA(1):1:x_range.DATA(2));

			DATA_delays_x_idx = (x_range.DATA(1):1:x_range.DATA(2));
			sequence_too_small_idx = find(autorate_log.DATA.LISTS.SEQUENCE < min_sequence_number);
			if ~isempty(sequence_too_small_idx)
				DATA_delays_x_idx = setdiff(DATA_delays_x_idx, sequence_too_small_idx);
			endif

			% allow to only plot a given reflector subset
			if ~isempty(selected_reflector_subset)
				cur_reflector_sample_idx = find(ismember(autorate_log.DATA.LISTS.REFLECTOR, selected_reflector_subset));
				DATA_delays_x_idx = intersect(DATA_delays_x_idx, cur_reflector_sample_idx);
			endif
			if isempty(DATA_delays_x_idx)
				disp('No valid samples found (for the current reflector subset).');
				%return # we can still plot the load/rate data, for long sleep periods there might be no valid delay samples at all
			endif

			% use real sample times, PROC_TIME_US is seconds.NNNNNN
			% to make things less odd report times in seconds since the log start
			x_vec.DATA = (autorate_log.DATA.LISTS.PROC_TIME_US - first_sample_timestamp);
			disp(['Selected DATA sample indices: ', num2str(x_range.DATA)]);

			% use this later to set the XLim s for all time plots
			x_vec_range = [x_vec.DATA(DATA_rates_x_idx(1)), x_vec.DATA(DATA_rates_x_idx(end))];
		else
			DATA_delays_x_idx = [];
			x_vec_range = [(60*60*24*365*1000) 0]; % make sure the following MIN/MAX operation will update the fields
		endif

		if (n_LOAD_samples > 0)
			LOAD_rates_x_idx = (x_range.LOAD(1):1:x_range.LOAD(2));
			x_vec.LOAD = (autorate_log.LOAD.LISTS.PROC_TIME_US - first_sample_timestamp);
			disp(['Selected LOAD sample indices: ', num2str(x_range.LOAD)]);
			% XLims should fit both DATA and LOAD sample timestamps
			x_vec_range(1) = min(x_vec_range(1), x_vec.LOAD(LOAD_rates_x_idx(1)));
			x_vec_range(2) = max(x_vec_range(2), x_vec.LOAD(LOAD_rates_x_idx(end)));
		endif
		x_label_string = 'time from log file start [sec]'; % or 'autorate samples'


		%TODO detect sleep periods and mark in graphs

		% for plot naming
		if ((x_range.DATA(1) ~= 1) ...
			|| ((n_DATA_samples > 0) && (x_range.DATA(2) ~= length(autorate_log.DATA.LISTS.RECORD_TYPE))) ...
			|| ((n_DATA_samples == 0) && (x_range.DATA(2) ~= length(autorate_log.LOAD.LISTS.RECORD_TYPE))))
			n_range_digits = ceil(max(log10(x_range.DATA)));
			range_string = ['.', 'sample_', num2str(x_range.DATA(1), ['%0', num2str(n_range_digits), 'd']), '_to_', num2str(x_range.DATA(2), ['%0', num2str(n_range_digits), 'd'])];
		else
			range_string = '';
		endif


		adjusted_ylim_delay = [];
		if ~isempty(scale_delay_axis_by_ADJ_DELAY_THR_factor) && (n_DATA_samples > 0)
			%ylim_delays = get(AX(2), 'YLim');
			if isfield(autorate_log.DATA.LISTS, 'ADJ_DELAY_THR')
				ul_max_adj_delay_thr = max(autorate_log.DATA.LISTS.ADJ_DELAY_THR(DATA_delays_x_idx));
				dl_max_adj_delay_thr = max(autorate_log.DATA.LISTS.ADJ_DELAY_THR(DATA_delays_x_idx));
			endif
			if isfield(autorate_log.DATA.LISTS, 'UL_ADJ_DELAY_THR')
				ul_max_adj_delay_thr = max(autorate_log.DATA.LISTS.UL_ADJ_DELAY_THR(DATA_delays_x_idx));
			endif
			if isfield(autorate_log.DATA.LISTS, 'DL_ADJ_DELAY_THR')
				dl_max_adj_delay_thr = max(autorate_log.DATA.LISTS.DL_ADJ_DELAY_THR(DATA_delays_x_idx));
			endif
			% delays.DATA.sign_list is orderd DL*, UL*, DL*, ...
			adjusted_ylim_delay(1) = (sign(delays.DATA.sign_list{2}) * ul_max_adj_delay_thr * scale_delay_axis_by_ADJ_DELAY_THR_factor);
			adjusted_ylim_delay(2) = (sign(delays.DATA.sign_list{1}) * dl_max_adj_delay_thr * scale_delay_axis_by_ADJ_DELAY_THR_factor);
			disp(['INFO: Adjusted y-limits based on ADJ_DELAY_THR_factor: ', num2str(adjusted_ylim_delay)]);
			%set(AX(2), 'YLim', (adjusted_ylim_delay * delays.DATA.scale_factor));
		end

		% find the 99%ile for the actual relevant delay data

		if ~isempty(scale_delay_axis_by_OWD_DELTA_QUANTILE_factor) && (n_DATA_samples > 0)
			sorted_UL_OWD_DELTA_US = sort(autorate_log.DATA.LISTS.UL_OWD_DELTA_US(DATA_delays_x_idx));
			n_UL_OWD_DELTA_US_samples = length(sorted_UL_OWD_DELTA_US);
			UL_OWD_DELTA_US_upper_quantile = sorted_UL_OWD_DELTA_US(round(n_UL_OWD_DELTA_US_samples * (OWD_DELTA_QUANTILE_pct / 100)));
			sorted_DL_OWD_DELTA_US = sort(autorate_log.DATA.LISTS.DL_OWD_DELTA_US(DATA_delays_x_idx));
			n_DL_OWD_DELTA_US_samples = length(sorted_DL_OWD_DELTA_US);
			DL_OWD_DELTA_US_upper_quantile = sorted_DL_OWD_DELTA_US(round(n_DL_OWD_DELTA_US_samples * (OWD_DELTA_QUANTILE_pct / 100)));
			% use this to correct the delay y-axis scaling
			% delays.DATA.sign_list is orderd DL*, UL*, DL*, ...
			DELAY_adjusted_ylim_delay(1) = (sign(delays.DATA.sign_list{2}) * UL_OWD_DELTA_US_upper_quantile * scale_delay_axis_by_OWD_DELTA_QUANTILE_factor);
			DELAY_adjusted_ylim_delay(2) = (sign(delays.DATA.sign_list{1}) * DL_OWD_DELTA_US_upper_quantile * scale_delay_axis_by_OWD_DELTA_QUANTILE_factor);

			% setting the range smaller or larger than minumum or maximum makes little sense...
			sorted_UL_OWD_US = sort(autorate_log.DATA.LISTS.UL_OWD_US(DATA_delays_x_idx));
			if DELAY_adjusted_ylim_delay(1) < (sign(delays.DATA.sign_list{2}) * 1.05 * sorted_UL_OWD_US(end))
				DELAY_adjusted_ylim_delay(1) = (sign(delays.DATA.sign_list{2}) * 1.05 * sorted_UL_OWD_US(end));
			endif
			sorted_DL_OWD_US = sort(autorate_log.DATA.LISTS.DL_OWD_US(DATA_delays_x_idx));
			if DELAY_adjusted_ylim_delay(2) > (sign(delays.DATA.sign_list{1}) * 1.05 * sorted_DL_OWD_US(end))
				DELAY_adjusted_ylim_delay(2) = (sign(delays.DATA.sign_list{1}) * 1.05 * sorted_DL_OWD_US(end));
			endif

			if isempty(adjusted_ylim_delay)
				adjusted_ylim_delay = DELAY_adjusted_ylim_delay;
				disp(['INFO: Adjusted y-limits based on OWD_DELTA_QUANTILE_factor: ', num2str(DELAY_adjusted_ylim_delay)]);
			else
				adjusted_ylim_delay(1) = sign(delays.DATA.sign_list{2})  * max([abs(adjusted_ylim_delay(1)), abs(DELAY_adjusted_ylim_delay(1))]);
				adjusted_ylim_delay(2) = max([adjusted_ylim_delay(2), DELAY_adjusted_ylim_delay(2)]);
				disp(['INFO: Grand adjusted y-limits based on OWD_DELTA_QUANTILE_factor and ADJ_DELAY_THR_factor: ', num2str(adjusted_ylim_delay)]);
			endif
		endif

		% for testing align_rate_and_delay_zeros
		%	autorate_log.DATA.LISTS.DL_OWD_US = 10*autorate_log.DATA.LISTS.DL_OWD_US;
		% for testing align_rate_and_delay_zeros
		%	autorate_log.DATA.LISTS.UL_OWD_US = 10*autorate_log.DATA.LISTS.UL_OWD_US;


		if (n_DATA_samples > 0)
			% create CDFs for each reflector, for both DL_OWD_US and UL_OWD_US
			% for low congestion state (low achieved rate with shaper at baseline rate)
			% and for high congestion state (high achieved rate close ot shaper rate)?

			% load conditions, ideally we want congestion condition, but the best estimate we have
			% are load conditions, since we want to look at differences in delay we should not
			% directly classify based on delay, hence load it is.
			sample_idx_by_load = fn_get_samples_by_load(autorate_log.DATA.LISTS, 'LOAD_PERCENT', {'UL', 'DL'}, {'UL_LOAD_PERCENT', 'DL_LOAD_PERCENT'}, CDF.LowLoad_threshold_percent, CDF.HighLoad_threshold_percent);

			if ismember('rawCDFs', plot_list);
				% measures for raw RTT/OWD data
				[raw_CDF, CDF_x_vec, unique_reflector_list] = fn_get_XDF_by_load('CDF', 'RAW', autorate_log.DATA.LISTS.UL_OWD_US, autorate_log.DATA.LISTS.DL_OWD_US, delays.DATA.scale_factor, ...
				CDF.calc_range_ms, CDF.step_size_ms, autorate_log.DATA.LISTS.REFLECTOR, sample_idx_by_load, DATA_delays_x_idx);
				if isempty(plot_FQN)
					cur_plot_FQN = fullfile(log_dir, [log_name, log_ext, '.rawCDFs', range_string, reflector_string, figure_opts.output_format_extension]);
				else
					cur_plot_FQN = fullfile(plot_path, [plot_name, '.rawCDFs', range_string, reflector_string, plot_ext]);
				endif
				autorate_rawCDF_fh = fn_plot_CDF_by_measure_and_load_condition('CDF', figure_opts, raw_CDF, CDF.cumulative_range_percent, 'raw delay [ms]', 'cumulative density [%]', cur_plot_FQN);
				% these can be pretty large, so make this somewhat lighter
				clear raw_CDF;
				clear CDF_x_vec;
			endif

			if ismember('rawPDFs', plot_list);
				% measures for raw RTT/OWD data
				[raw_PDF, PDF_x_vec, unique_reflector_list] = fn_get_XDF_by_load('PDF', 'RAW', autorate_log.DATA.LISTS.UL_OWD_US, autorate_log.DATA.LISTS.DL_OWD_US, delays.DATA.scale_factor, ...
				PDF.calc_range_ms, PDF.step_size_ms, autorate_log.DATA.LISTS.REFLECTOR, sample_idx_by_load, DATA_delays_x_idx);
				if isempty(plot_FQN)
					cur_plot_FQN = fullfile(log_dir, [log_name, log_ext, '.rawPDFs', range_string, reflector_string, figure_opts.output_format_extension]);
				else
					cur_plot_FQN = fullfile(plot_path, [plot_name, '.rawPDFs', range_string, reflector_string, plot_ext]);
				endif
				autorate_rawPDF_fh = fn_plot_CDF_by_measure_and_load_condition('PDF', figure_opts, raw_PDF, PDF.cumulative_range_percent, 'raw delay [ms]', 'probability density [%]', cur_plot_FQN);
				% these can be pretty large, so make this somewhat lighter
				clear raw_PDF;
				clear PDF_x_vec;
			endif


			if ismember('deltaCDFs', plot_list);
				% measures for base-loine corrected delta(RTT)/delta(OWD) data
				[delta_CDF, CDF_x_vec, unique_reflector_list] = fn_get_XDF_by_load('CDF', 'DELTA', autorate_log.DATA.LISTS.UL_OWD_DELTA_US, autorate_log.DATA.LISTS.DL_OWD_DELTA_US, delays.DATA.scale_factor, ...
				CDF.calc_range_ms, CDF.step_size_ms, autorate_log.DATA.LISTS.REFLECTOR, sample_idx_by_load, DATA_delays_x_idx);
				if isempty(plot_FQN)
					cur_plot_FQN = fullfile(log_dir, [log_name, log_ext, '.deltaCDFs', range_string, reflector_string, figure_opts.output_format_extension]);
				else
					cur_plot_FQN = fullfile(plot_path, [plot_name, '.deltaCDFs', range_string, reflector_string, plot_ext]);
				endif
				autorate_deltaCDF_fh = fn_plot_CDF_by_measure_and_load_condition('CDF', figure_opts, delta_CDF, CDF.cumulative_range_percent, 'delta delay [ms]', 'cumulative density [%]', cur_plot_FQN);
				fn_propose_delay_thresholds(delta_CDF, CDF.calc_range_ms);
				% these can be pretty large, so make this somewhat lighter
				clear delta_CDF;
				clear CDF_x_vec;
			endif

			if ismember('deltaPDFs', plot_list);
				% measures for base-loine corrected delta(RTT)/delta(OWD) data
				[delta_PDF, PDF_x_vec, unique_reflector_list] = fn_get_XDF_by_load('PDF', 'DELTA', autorate_log.DATA.LISTS.UL_OWD_DELTA_US, autorate_log.DATA.LISTS.DL_OWD_DELTA_US, delays.DATA.scale_factor, ...
				PDF.calc_range_ms, PDF.step_size_ms, autorate_log.DATA.LISTS.REFLECTOR, sample_idx_by_load, DATA_delays_x_idx);
				if isempty(plot_FQN)
					cur_plot_FQN = fullfile(log_dir, [log_name, log_ext, '.deltaPDFs', range_string, reflector_string, figure_opts.output_format_extension]);
				else
					cur_plot_FQN = fullfile(plot_path, [plot_name, '.deltaPDFs', range_string, reflector_string, plot_ext]);
				endif
				autorate_deltaCDF_fh = fn_plot_CDF_by_measure_and_load_condition('PDF', figure_opts, delta_PDF, PDF.cumulative_range_percent, 'delta delay [ms]', 'probability density [%]', cur_plot_FQN);
				% these can be pretty large, so make this somewhat lighter
				clear delta_PDF;
				clear PDF_x_vec;
			endif
		endif


		if ismember('timecourse', plot_list);
			% plot timecourses

			autorate_fh = figure('Name', 'CAKE-autorate log: rate & delay timecourses', 'visible', figure_visibility_string);
			[ output_rect ] = fn_set_figure_outputpos_and_size( autorate_fh, 1, 1, 27, 19, 1, 'landscape', 'centimeters' );
			if (n_DATA_samples > 0)
				cur_sph = subplot(2, 2, [1 2]);
				%plot data on both axes
				% use this as dummy to create the axis:
				cur_scaled_data_rates = autorate_log.DATA.LISTS.(rates.DATA.fields_to_plot_list{1})(DATA_rates_x_idx) * rates.DATA.scale_factor;
				cur_scaled_data_delays = autorate_log.DATA.LISTS.(delays.DATA.fields_to_plot_list{1})(DATA_delays_x_idx) * delays.DATA.scale_factor;

				if (isempty(cur_scaled_data_rates) || isempty(cur_scaled_data_delays))
					disp('WARNING: We somehow ended up without data to plot, should not happen');
					return
				endif

				% this is a dummy plot so we get the dual axis handles...
				[AX H1 H2] = plotyy(x_vec.DATA(DATA_delays_x_idx), (delays.DATA.sign_list{1} * cur_scaled_data_delays)', x_vec.DATA(DATA_rates_x_idx)', (rates.DATA.sign_list{1} * cur_scaled_data_rates)', 'plot');
				%hold both axes
				legend_list = {};
				hold(AX(1));
				for i_field = 1 : length(delays.DATA.fields_to_plot_list)
					legend_list{end+1} = delays.DATA.fields_to_plot_list{i_field};
					cur_scaled_data = autorate_log.DATA.LISTS.(delays.DATA.fields_to_plot_list{i_field})(DATA_delays_x_idx) * delays.DATA.scale_factor;
					plot(AX(1), x_vec.DATA(DATA_delays_x_idx)', (delays.DATA.sign_list{i_field} * cur_scaled_data)', 'Color', delays.DATA.color_list{i_field}, 'Linestyle', delays.DATA.linestyle_list{i_field}, 'LineWidth', line_width);
				endfor
				%legend(legend_list, 'Interpreter', 'none');
				hold off
				xlabel(x_label_string);
				ylabel('Delay [milliseconds]');
				set(AX(1), 'XLim', x_vec_range);

				if ~isempty(adjusted_ylim_delay)
					set(AX(1), 'YLim', (adjusted_ylim_delay * delays.DATA.scale_factor));
				end

				hold(AX(2));
				for i_field = 1 : length(rates.DATA.fields_to_plot_list)
					legend_list{end+1} = rates.DATA.fields_to_plot_list{i_field};
					cur_scaled_data = autorate_log.DATA.LISTS.(rates.DATA.fields_to_plot_list{i_field})(DATA_rates_x_idx) * rates.DATA.scale_factor;
					plot(AX(2), x_vec.DATA(DATA_rates_x_idx)', (rates.DATA.sign_list{i_field} * cur_scaled_data)', 'Color', rates.DATA.color_list{i_field}, 'Linestyle', rates.DATA.linestyle_list{i_field}, 'LineWidth', line_width);
				endfor

				if (n_LOAD_samples > 0)
					for i_field = 1 : length(rates.LOAD.fields_to_plot_list)
						legend_list{end+1} = rates.LOAD.fields_to_plot_list{i_field};
						cur_scaled_data = autorate_log.LOAD.LISTS.(rates.LOAD.fields_to_plot_list{i_field})(LOAD_rates_x_idx) * rates.LOAD.scale_factor;
						plot(AX(2), x_vec.LOAD(LOAD_rates_x_idx)', (rates.LOAD.sign_list{i_field} * cur_scaled_data)', 'Color', rates.LOAD.color_list{i_field}, 'Linestyle', rates.LOAD.linestyle_list{i_field}, 'LineWidth', line_width);
					endfor
				endif
				%legend(legend_list, 'Interpreter', 'none');
				hold off
				xlabel(AX(2), x_label_string);
				ylabel(AX(2), 'Rate [Mbps]');
				set(AX(2), 'XLim', x_vec_range);

				% make sure the zeros of both axes align
				if (align_rate_and_delay_zeros)
					ylim_rates = get(AX(2), 'YLim');
					ylim_delays = get(AX(1), 'YLim');

					rate_up_ratio = abs(ylim_rates(1)) / sum(abs(ylim_rates));
					rate_down_ratio = abs(ylim_rates(2)) / sum(abs(ylim_rates));

					delay_up_ratio = abs(ylim_delays(1)) / sum(abs(ylim_delays));
					delay_down_ratio = abs(ylim_delays(2)) / sum(abs(ylim_delays));

					if (delay_up_ratio >= rate_up_ratio)
						% we need to adjust the upper limit
						new_lower_y_delay = ylim_delays(1);
						new_upper_y_delay = (abs(ylim_delays(1)) / rate_up_ratio) - abs(ylim_delays(1));

					else
						% we need to adjust the lower limit
						new_lower_y_delay = sign(ylim_delays(1)) * ((abs(max(ylim_delays)) / rate_down_ratio) - abs(max(ylim_delays)));
						new_upper_y_delay = ylim_delays(2);
					endif
					set(AX(1), 'YLim', [new_lower_y_delay, new_upper_y_delay]);
				endif

				% TODO: look at both DATA and LOAD timestamps to deduce the start and end timestamps
				title(AX(2), ['Start: ', autorate_log.DATA.LISTS.LOG_DATETIME{DATA_rates_x_idx(1)}, '; ', num2str(autorate_log.DATA.LISTS.LOG_TIMESTAMP(DATA_rates_x_idx(1))), '; sample index: ', num2str(x_range.DATA(1)); ...
				'End:   ', autorate_log.DATA.LISTS.LOG_DATETIME{DATA_rates_x_idx(end)}, '; ', num2str(autorate_log.DATA.LISTS.LOG_TIMESTAMP(DATA_rates_x_idx(end))), '; sample index: ', num2str(x_range.DATA(2))]);
			endif



			cur_sph = subplot(2, 2, 3);
			% rates
			hold on
			legend_list = {};
			if (n_DATA_samples > 0)
				for i_field = 1 : length(rates.DATA.fields_to_plot_list)
					legend_list{end+1} = rates.DATA.fields_to_plot_list{i_field};
					cur_scaled_data = autorate_log.DATA.LISTS.(rates.DATA.fields_to_plot_list{i_field})(DATA_rates_x_idx) * rates.DATA.scale_factor;
					plot(x_vec.DATA(DATA_rates_x_idx)', (rates.DATA.sign_list{i_field} * cur_scaled_data)', 'Color', rates.DATA.color_list{i_field}, 'Linestyle', rates.DATA.linestyle_list{i_field}, 'LineWidth', line_width);
				endfor
			endif
			if (n_LOAD_samples > 0)
				for i_field = 1 : length(rates.LOAD.fields_to_plot_list)
					legend_list{end+1} = rates.LOAD.fields_to_plot_list{i_field};
					cur_scaled_data = autorate_log.LOAD.LISTS.(rates.LOAD.fields_to_plot_list{i_field})(LOAD_rates_x_idx) * rates.LOAD.scale_factor;
					plot(cur_sph, x_vec.LOAD(LOAD_rates_x_idx)', (rates.LOAD.sign_list{i_field} * cur_scaled_data)', 'Color', rates.LOAD.color_list{i_field}, 'Linestyle', rates.LOAD.linestyle_list{i_field}, 'LineWidth', line_width);
				endfor
			endif

			if ~isempty(legend_list)
				try
					if strcmp(graphics_toolkit, 'gnuplot')
						legend(legend_list, 'Interpreter', 'none', 'box', 'off', 'location', 'northoutside', 'FontSize', 7);
					else
						legend(legend_list, 'Interpreter', 'none', 'numcolumns', 2, 'box', 'off', 'location', 'northoutside', 'FontSize', 7);
					end
				catch
					disp(['Triggered']);
					legend(legend_list, 'Interpreter', 'none', 'box', 'off', 'FontSize', 7);
				end_try_catch
			end
			hold off
			xlabel(x_label_string);
			ylabel('Rate [Mbps]');
			set(cur_sph, 'XLim', x_vec_range);

			if (n_DATA_samples > 0)
				cur_sph = subplot(2, 2, 4);
				% delays
				hold on
				legend_list = {};
				for i_field = 1 : length(delays.DATA.fields_to_plot_list)
					legend_list{end+1} = delays.DATA.fields_to_plot_list{i_field};
					cur_scaled_data = autorate_log.DATA.LISTS.(delays.DATA.fields_to_plot_list{i_field})(DATA_delays_x_idx) * delays.DATA.scale_factor;
					plot(x_vec.DATA(DATA_delays_x_idx)', (delays.DATA.sign_list{i_field} * cur_scaled_data)', 'Color', delays.DATA.color_list{i_field}, 'Linestyle', delays.DATA.linestyle_list{i_field}, 'LineWidth', line_width);
				endfor
				if ~isempty(adjusted_ylim_delay)
					set(cur_sph, 'YLim', (adjusted_ylim_delay * delays.DATA.scale_factor));
				endif
				if ~isempty(legend_list)
					try
						if strcmp(graphics_toolkit, 'gnuplot')
							legend(legend_list, 'Interpreter', 'none', 'box', 'off', 'location', 'northoutside', 'FontSize', 7);
						else
							legend(legend_list, 'Interpreter', 'none', 'numcolumns', 3, 'box', 'off', 'location', 'northoutside', 'FontSize', 7);
						end
					catch
						legend(legend_list, 'Interpreter', 'none', 'box', 'off', 'FontSize', 7);
					end_try_catch
				end
				hold off
				xlabel(x_label_string);
				ylabel('Delay [milliseconds]');
				set(cur_sph, 'XLim', x_vec_range);
			endif

			if isempty(plot_FQN)
				cur_plot_FQN = fullfile(log_dir, [log_name, log_ext, '.timecourse', range_string, reflector_string, output_format_extension]);
			else
				cur_plot_FQN = fullfile(plot_path, [plot_name, '.timecourse', range_string, reflector_string, plot_ext]);
			endif

			disp(['INFO: Writing plot as: ', cur_plot_FQN]);
			write_out_figure(autorate_fh, cur_plot_FQN, [], []);
		endif
	catch err
    warning(err.identifier, err.message);
		err
		for i_stack = 1 : length(err.stack)
			disp(['Stack #: ', num2str(i_stack), ':']);
			disp(err.stack(i_stack));
		endfor

		disp('INFO: available graphics toolkits:');
		disp(available_graphics_toolkits);
		disp(['INFO: Selected graphics toolkit: ', graphics_toolkit]);
		disp(['INFO: Octave version: ', version]);
		disp('Please report any issue to https://github.com/lynxthecat/cake-autorate/issues and consider sharing the log file that revealed the problem.');
	end_try_catch

	% verbose exit
	timestamps.(mfilename).end = toc(timestamps.(mfilename).start);
	disp(['INFO: ', mfilename, ' took: ', num2str(timestamps.(mfilename).end), ' seconds.']);

	return
endfunction


function [ autorate_log, log_FQN ] = fn_parse_autorate_logfile( log_FQN, command_string )
	% variables
	debug = 0;
	delimiter_string = ";";	% what separator is used in the log file
	line_increment = 100;		%  by what size to increment data structures on hitting the end
	% enumerate all field names in HEADER that denote a string field on DATA records, otherwise default to numeric
	string_field_identifier_list = {'RECORD_TYPE', 'LOG_DATETIME', 'REFLECTOR', '_LOAD_CONDITION'};

	autorate_log = struct();

	% global variables so we can grow these from helper functions without shuttling too much data around all the time...
	global log_struct

	log_struct = [];
	log_struct.INFO = [];
	log_struct.DEBUG = [];
	log_struct.HEADER = [];
	log_struct.DATA = [];
	log_struct.LOAD_HEADER = [];
	log_struct.LOAD = [];
	log_struct.REFLECTOR_HEADER = [];
	log_struct.REFLECTOR = [];
	log_struct.INFO = [];
	log_struct.SHAPER = [];
	log_struct.metainformation = [];
  log_struct.SUMMARY_HEADER = [];
	log_struct.SUMMARY = [];


	%TODO: merge current and old log file if they can be found...

	if ~exist('log_FQN', 'var') || isempty(log_FQN)
		% open a ui file picker
		%[log_name, log_dir, fld_idx] = uigetfile("*.log", "Select one or more autorate log files:", "MultiSelect", "on");
		[log_name, log_dir, fld_idx] = uigetfile({"*.log; *.log.old; *log.old.gz; *.log.gz; *.gz", "Known Log file extensions"}, "Select one or more autorate log files:");
		log_FQN = fullfile(log_dir, log_name);
	endif

	if ~exist('command_string', 'var') || isempty(command_string)
		command_string = 'load_existing';
	endif

	% dissect the fully qualified name
	[log_dir, log_name, log_ext ] = fileparts(log_FQN);


	% deal with gzipped log files
	if strcmp(log_ext, '.GZ')
		disp('INFO: Octave gunzip does not tolerate upper-case .GZ extensions,  renaming to lower-case .gz');
		movefile(log_FQN, fullfile(log_dir, [log_name, '.gz']));
		log_FQN = fullfile(log_dir, [log_name, '.gz']);
		[log_dir, log_name, log_ext ] = fileparts(log_FQN);
	endif
	if strcmp(log_ext, '.gz')
		file_list = gunzip(log_FQN);
		if (length(file_list) == 1)
			orig_log_FQN = log_FQN;
			log_FQN = file_list{1};
			[log_dir, log_name, log_ext ] = fileparts(log_FQN);
		else
			error(['WARNING: Archive contains more than one file, bailig out: ', log_FQN]);
		endif
	endif

	if exist(fullfile(log_dir, [log_name, log_ext, '.mat']), 'file') && strcmp(command_string, 'load_existing')
		disp(['INFO: Found already parsed log file (', fullfile(log_dir, [log_name, log_ext, '.mat']), '), loading...']);
		load(fullfile(log_dir, [log_name, log_ext, '.mat']));
		return
	endif

	% now read the file line by line and steer each line into the correct structure.
	% if this would not be intereaved things would be easier
	log_fd = fopen(log_FQN);
	if log_fd == -1
		error(["ERROR: Could not open: ", log_FQN]);
	endif

	cur_record_type = "";
	% get started
	disp(['INFO: Parsing log file: ', log_FQN]);
	disp('INFO: might take a while...');
	line_count = 0;
	while (!feof(log_fd) )
		% get the next line
		current_line = fgetl(log_fd);
		line_count = line_count + 1;

		if (debug)
			disp([num2str(line_count), ': ', current_line]);
		endif

    if (length(current_line) < 5)
      disp('WARN: line shorter than 5 chars, skip parsing of this line...');
      continue
    endif

		cur_record_type = fn_get_record_type_4_line(current_line, delimiter_string, string_field_identifier_list);
    try
	    fn_parse_current_line(cur_record_type, current_line, delimiter_string, line_increment);
    catch
      disp(['WARN: Parsing of line ', num2str(line_count), ' failed. Line content:']);
      disp(current_line);
      disp(['WARN: Will skip this line, but the rest of the parsing might fail, please check the raw logfile....']);
      %keyboard
      continue
    end_try_catch


		if ~(mod(line_count, 1000))
			% give some feed back, however this is expensive so do so rarely
			disp(['INFO: Processed line: ', num2str(line_count)]);
			fflush(stdout) ;
		endif
		%disp(current_line)
	endwhile

	% clean-up
	fclose(log_fd);

	% shrink global datastructures
	fn_shrink_global_LISTS({"DEBUG", "INFO", "DATA", "SHAPER", "LOAD", "SUMMARY"});

	% ready for export and
	autorate_log = log_struct;

	% save autorate_log as mat file...
	disp(['INFO: Saving parsed data file as: ', fullfile(log_dir, [log_name, log_ext, '.mat'])]);
	save(fullfile(log_dir, [log_name, log_ext, '.mat']), 'autorate_log', '-7');

	if ~exist(fullfile(log_dir, [log_name, log_ext, '.gz']), 'file')
		% compress the uncompressed log
		FILELIST = gzip(fullfile(log_dir, [log_name, log_ext]));
	end

	if exist(fullfile(log_dir, [log_name, log_ext]), 'file');
		% delete the uncompressed log
		delete(fullfile(log_dir, [log_name, log_ext]));
	endif

	return
endfunction


function in = isoctave()
	persistent inout;

	if isempty(inout),
		inout = exist('OCTAVE_VERSION','builtin') ~= 0;
	end
	in = inout;

	return;
endfunction


function [ sanitized_name ]  = sanitize_name_for_matlab( input_name )
	% some characters are not really helpful inside matlab variable names, so
	% replace them with something that should not cause problems
	taboo_char_list =		{' ', '-', '.', '=', '/', '[', ']'};
	replacement_char_list = {'_', '_', '_dot_', '_eq_', '_', '_', '_'};

	taboo_first_char_list = {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9'};
	replacement_firts_char_list = {'Zero', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine'};

	sanitized_name = input_name;
	% check first character to not be a number
	taboo_first_char_idx = find(ismember(taboo_first_char_list, input_name(1)));
	if ~isempty(taboo_first_char_idx)
		sanitized_name = [replacement_firts_char_list{taboo_first_char_idx}, input_name(2:end)];
	end

	for i_taboo_char = 1: length(taboo_char_list)
		current_taboo_string = taboo_char_list{i_taboo_char};
		current_replacement_string = replacement_char_list{i_taboo_char};
		current_taboo_processed = 0;
		remain = sanitized_name;
		tmp_string = '';
		while (~current_taboo_processed)
			[token, remain] = strtok(remain, current_taboo_string);
			tmp_string = [tmp_string, token, current_replacement_string];
			if isempty(remain)
				current_taboo_processed = 1;
				% we add one superfluous replacement string at the end, so
				% remove that
				tmp_string = tmp_string(1:end-length(current_replacement_string));
			end
		end
		sanitized_name = tmp_string;
	end

	return
endfunction


function [ cur_record_type ] = fn_get_record_type_4_line( current_line, delimiter_string, string_field_identifier_list )
	% define some information for the individual record types

	global log_struct
	cur_record_type = [];

	% deal with CTRL-C?
	%if strcmp(current_line(1:2), '')

	switch current_line(1:5)
		case {"DEBUG"}
			cur_record_type = "DEBUG";
			if ~isfield(log_struct.metainformation, 'DEBUG')
				log_struct.metainformation.DEBUG.count = 1;
			else
				log_struct.metainformation.DEBUG.count = log_struct.metainformation.DEBUG.count + 1;
			endif
		case {"DATA_", "HEADE"}
			cur_record_type = "HEADER";
			if ~isfield(log_struct.metainformation, 'HEADER')
				log_struct.metainformation.HEADER.count = 1;
			else
				log_struct.metainformation.HEADER.count = log_struct.metainformation.HEADER.count + 1;
			endif
		case {"DATA;"}
			cur_record_type = "DATA";
			if ~isfield(log_struct.metainformation, 'HEADER') || log_struct.metainformation.HEADER.count < 1
				# we have not encountered a DATA_HEADER record yet and do not know how to parse DATA records, so SKIP
				cur_record_type = "SKIP";
				if ~isfield(log_struct.metainformation, 'SKIP_DATA')
					log_struct.metainformation.SKIP_DATA.count = 1;
				else
					log_struct.metainformation.SKIP_DATA.count = log_struct.metainformation.SKIP_DATA.count + 1;
				endif
				disp(['Found DATA before DATA_HEADER record, unable to parse, skipping (N: ', num2str(log_struct.metainformation.SKIP_DATA.count), ').']);
			else
				# this is fine we already found a header
				if ~isfield(log_struct.metainformation, 'DATA')
					log_struct.metainformation.DATA.count = 1;
				else
					log_struct.metainformation.DATA.count = log_struct.metainformation.DATA.count + 1;
				endif
			endif
		case {"LOAD_"}
			cur_record_type = "LOAD_HEADER";
			if ~isfield(log_struct.metainformation, 'LOAD_HEADER')
				log_struct.metainformation.LOAD_HEADER.count = 1;
			else
				log_struct.metainformation.LOAD_HEADER.count = log_struct.metainformation.LOAD_HEADER.count + 1;
			endif
		case {"LOAD;"}
			cur_record_type = "LOAD";
			if ~isfield(log_struct.metainformation, 'LOAD_HEADER') || log_struct.metainformation.LOAD_HEADER.count < 1
				# we have not encountered a LOAD_HEADER record yet and do not know how to parse LOAD records, so SKIP
				cur_record_type = "SKIP";
				if ~isfield(log_struct.metainformation, 'SKIP_LOAD')
					log_struct.metainformation.SKIP_LOAD.count = 1;
				else
					log_struct.metainformation.SKIP_LOAD.count = log_struct.metainformation.SKIP_LOAD.count + 1;
				endif
				disp(['Found LOAD before LOAD_HEADER record, unable to parse, skipping (N: ', num2str(log_struct.metainformation.SKIP_LOAD.count), ').']);
			else
				# this is fine we already found a header

				if ~isfield(log_struct.metainformation, 'LOAD')
					log_struct.metainformation.LOAD.count = 1;
				else
					log_struct.metainformation.LOAD.count = log_struct.metainformation.LOAD.count + 1;
				endif
			endif
		case {"REFLE"}
			if strcmp(current_line(1:16), "REFLECTOR_HEADER")
				cur_record_type = "REFLECTOR_HEADER";
				if ~isfield(log_struct.metainformation, 'REFLECTOR_HEADER')
					%log_struct.REFLECTOR_HEADER = [];
					log_struct.metainformation.REFLECTOR_HEADER.count = 1;
				else
					log_struct.metainformation.REFLECTOR_HEADER.count = log_struct.metainformation.REFLECTOR_HEADER.count + 1;
				endif
			elseif strcmp(current_line(1:10), "REFLECTOR;")
				cur_record_type = "REFLECTOR";
				if ~isfield(log_struct.metainformation, 'REFLECTOR_HEADER') || log_struct.metainformation.REFLECTOR_HEADER.count < 1
					# we have not encountered a REFLECTOR_HEADER record yet and do not know how to parse REFLECTOR records, so SKIP
					cur_record_type = "SKIP";
					if ~isfield(log_struct.metainformation, 'SKIP_REFLECTOR')
						log_struct.metainformation.SKIP_REFLECTOR.count = 1;
					else
						log_struct.metainformation.SKIP_REFLECTOR.count = log_struct.metainformation.SKIP_REFLECTOR.count + 1;
					endif
					disp(['Found REFLECTOR before REFLECTOR_HEADER record, unable to parse, skipping (N: ', num2str(log_struct.metainformation.SKIP_REFLECTOR.count), ').']);
				else
					# this is fine we already found a header
					if ~isfield(log_struct.metainformation, 'REFLECTOR')
						%log_struct.REFLECTOR = [];
						log_struct.metainformation.REFLECTOR.count = 1;
					else
						log_struct.metainformation.REFLECTOR.count = log_struct.metainformation.REFLECTOR.count + 1;
					endif
				endif
      endif
    case {"SUMMA"}
      if strcmp(current_line(1:14), "SUMMARY_HEADER")
        cur_record_type = "SUMMARY_HEADER";
        if ~isfield(log_struct.metainformation, 'SUMMARY_HEADER')
          %log_struct.SUMMARY_HEADER = [];
          log_struct.metainformation.SUMMARY_HEADER.count = 1;
        else
          log_struct.metainformation.SUMMARY_HEADER.count = log_struct.metainformation.SUMMARY_HEADER.count + 1;
        endif
      elseif strcmp(current_line(1:8), "SUMMARY;")
        cur_record_type = "SUMMARY";
        if ~isfield(log_struct.metainformation, 'SUMMARY_HEADER') || log_struct.metainformation.SUMMARY_HEADER.count < 1
          # we have not encountered a SUMMARY_HEADER record yet and do not know how to parse SUMMARY records, so SKIP
          cur_record_type = "SKIP";
          if ~isfield(log_struct.metainformation, 'SKIP_SUMMARY')
            log_struct.metainformation.SKIP_SUMMARY.count = 1;
          else
            log_struct.metainformation.SKIP_SUMMARY.count = log_struct.metainformation.SKIP_SUMMARY.count + 1;
          endif
          disp(['Found SUMMARY before SUMMARY_HEADER record, unable to parse, skipping (N: ', num2str(log_struct.metainformation.SKIP_SUMMARY.count), ').']);
        else
          # this is fine we already found a header
          if ~isfield(log_struct.metainformation, 'SUMMARY')
            %log_struct.REFLECTOR = [];
            log_struct.metainformation.SUMMARY.count = 1;
          else
            log_struct.metainformation.SUMMARY.count = log_struct.metainformation.SUMMARY.count + 1;
          endif
        endif
      endif
  case {"SHAPE"}
    cur_record_type = "SHAPER";
    if ~isfield(log_struct.metainformation, 'SHAPER')
      log_struct.metainformation.SHAPER.count = 1;
    else
      log_struct.metainformation.SHAPER.count = log_struct.metainformation.SHAPER.count + 1;
    endif
  case {"INFO;"}
    cur_record_type = "INFO";
    if ~isfield(log_struct.metainformation, 'INFO')
      log_struct.metainformation.INFO.count = 1;
    else
      log_struct.metainformation.INFO.count = log_struct.metainformation.INFO.count + 1;
    endif
  case {"/root"}
    % example for single shot logging...
    cur_record_type = "SKIP_root";
    if ~isfield(log_struct.metainformation, 'SKIP_root')
      log_struct.metainformation.SKIP_root.count = 1;
      % only warn once
      disp(["WARNING: Unhandled type identifier encountered: ", current_line(1:5), ' only noting once...']);
    else
      log_struct.metainformation.SKIP_root.count = log_struct.metainformation.SKIP_root.count + 1;
    endif
  otherwise
    % this will be logged multiple times, but it can be triggered by different lines, so this seems OK.
    disp(["WARNING: Unhandled type identifier encountered: ", current_line(1:5), ' trying to ignore...']);
    %error("ERROR: Not handled yet, bailing out...");
    cur_record_type = "SKIP";
    if ~isfield(log_struct.metainformation, 'SKIP')
      log_struct.metainformation.SKIP.count = 1;
    else
      log_struct.metainformation.SKIP.count = log_struct.metainformation.SKIP.count + 1;
    endif
endswitch

% define the parsing strings
switch cur_record_type
  case {"DEBUG"}
    if ~isfield(log_struct.DEBUG, 'listtypes') || isempty(log_struct.DEBUG.listtypes)
      log_struct.DEBUG.listnames = {"TYPE", "LOG_DATETIME", "LOG_TIMESTAMP", "MESSAGE"};#
      log_struct.DEBUG.listtypes = {"%s", "%s", "%f", "%s"};
      log_struct.DEBUG.format_string = fn_compose_format_string(log_struct.DEBUG.listtypes);
    endif
  case {"HEADER", "DATA_"}
    if ~isfield(log_struct.HEADER, 'listtypes') || isempty(log_struct.DEBUG.listtypes)
      fn_extract_DATA_names_types_format_from_HEADER(current_line, delimiter_string, string_field_identifier_list, 'HEADER', 'DATA');
      % HEADER stays mostly empty
      %log_struct.HEADER.format_string = "";
      %log_struct.HEADER.listnames = {};	% no lists just use these to deduce the list/fieldnames for the DATA records
      %log_struct.HEADER.listtypes = {};
    endif
  case {"DATA"}
    if ~isfield(log_struct.DATA, 'listtypes') || isempty(log_struct.DATA.listtypes)
      %throw error as this needs to be filled from header already...
      % fill this from the header
      log_struct.DATA.format_string = "";
      log_struct.DATA.listnames = {};	% no lists just use these to deduce the list/fieldnames for the DATA records
      log_struct.DATA.listtypes = {};
    endif
  case {"LOAD_HEADER"}
    if ~isfield(log_struct.LOAD_HEADER, 'listtypes') || isempty(log_struct.DEBUG.listtypes)
      fn_extract_DATA_names_types_format_from_HEADER(current_line, delimiter_string, string_field_identifier_list, 'LOAD_HEADER', 'LOAD');
      % HEADER stays mostly empty
      %log_struct.HEADER.format_string = "";
      %log_struct.HEADER.listnames = {};	% no lists just use these to deduce the list/fieldnames for the DATA records
      %log_struct.HEADER.listtypes = {};
    endif
  case {"LOAD"}
    if ~isfield(log_struct.LOAD, 'listtypes') || isempty(log_struct.LOAD.listtypes)
      %throw error as this needs to be filled from header already...
      % fill this from the header
      log_struct.LOAD.format_string = "";
      log_struct.LOAD.listnames = {};	% no lists just use these to deduce the list/fieldnames for the DATA records
      log_struct.LOAD.listtypes = {};
    endif
  case {"REFLECTOR_HEADER"}
    if ~isfield(log_struct.REFLECTOR_HEADER, 'listtypes') || isempty(log_struct.REFLECTOR_HEADER.listtypes)
      fn_extract_DATA_names_types_format_from_HEADER(current_line, delimiter_string, string_field_identifier_list, 'REFLECTOR_HEADER', 'REFLECTOR');
      % HEADER stays mostly empty
      %log_struct.REFLECTOR_HEADER.format_string = "";
      %log_struct.REFLECTOR_HEADER.listnames = {};	% no lists just use these to deduce the list/fieldnames for the DATA records
      %log_struct.REFLECTOR_HEADER.listtypes = {};
    endif
  case {"REFLECTOR"}
    if ~isfield(log_struct.REFLECTOR, 'listtypes') || isempty(log_struct.REFLECTOR.listtypes)
      %throw error as this needs to be filled from header already...
      % fill this from the header
      log_struct.REFLECTOR.format_string = "";
      log_struct.REFLECTOR.listnames = {};	% no lists just use these to deduce the list/fieldnames for the DATA records
      log_struct.REFLECTOR.listtypes = {};
    endif
  case {"SUMMARY_HEADER"}
    if ~isfield(log_struct.SUMMARY_HEADER, 'listtypes') || isempty(log_struct.SUMMARY_HEADER.listtypes)
      fn_extract_DATA_names_types_format_from_HEADER(current_line, delimiter_string, string_field_identifier_list, 'SUMMARY_HEADER', 'SUMMARY');
      % HEADER stays mostly empty
      %log_struct.SUMMARY_HEADER.format_string = "";
      %log_struct.SUMMARY_HEADER.listnames = {};	% no lists just use these to deduce the list/fieldnames for the DATA records
      %log_struct.SUMMARY_HEADER.listtypes = {};
    endif
  case {"SUMMARY"}
    if ~isfield(log_struct.SUMMARY, 'listtypes') || isempty(log_struct.SUMMARY.listtypes)
      %throw error as this needs to be filled from header already...
      % fill this from the header
      log_struct.SUMMARY.format_string = "";
      log_struct.SUMMARY.listnames = {};	% no lists just use these to deduce the list/fieldnames for the SUMMARY records
      log_struct.SUMMARY.listtypes = {};
    endif
  case {"SHAPER"}
    if ~isfield(log_struct.SHAPER, 'listtypes') || isempty(log_struct.SHAPER.listtypes)
      log_struct.SHAPER.listnames = {"TYPE", "LOG_DATETIME", "LOG_TIMESTAMP", "MESSAGE"};
      log_struct.SHAPER.listtypes = {"%s", "%s", "%f", "%s"};
      log_struct.SHAPER.format_string = fn_compose_format_string(log_struct.SHAPER.listtypes);
    endif
  case {"INFO"}
    if ~isfield(log_struct.INFO, 'listtypes') || isempty(log_struct.INFO.listtypes)
      log_struct.INFO.listnames = {"TYPE", "LOG_DATETIME", "LOG_TIMESTAMP", "MESSAGE"};
      log_struct.INFO.listtypes = {"%s", "%s", "%f", "%s"};
      log_struct.INFO.format_string = fn_compose_format_string(log_struct.INFO.listtypes);
    endif
  case {"SKIP_root", "SKIP"}
    % ignore these.
  otherwise
    disp(["WARNING: Unhandled record_type  encountered: ", cur_record_type, ' trying to ignore...']);
    %error("ERROR: Not handled yet, bailing out...");
endswitch

return
endfunction


function [ ] = fn_parse_current_line( cur_record_type, current_line, delimiter_string, line_increment)
global log_struct

if ~ismember(cur_record_type, {'INFO', 'SHAPER', 'DEBUG', 'DATA', 'LOAD', 'REFLECTOR', 'SUMMARY'}) % {'DEBUG', 'INFO', 'SJHAPER'}
  return
endif

##	% ignore HEADER records
##	if ismember(cur_record_type, {'HEADER'})
##		return
##	endif

if ~isfield(log_struct.(cur_record_type), "LISTS") || isempty(log_struct.(cur_record_type).LISTS )
  log_struct.(cur_record_type).last_valid_data_idx = 0;
  for i_list = 1 : length(log_struct.(cur_record_type).listnames)
    cur_listname = log_struct.(cur_record_type).listnames{i_list};
    cur_listtype = log_struct.(cur_record_type).listtypes{i_list};
    % put strings into cells and numeric data into proper double arrays
    switch cur_listtype
      case {"%s"}
        log_struct.(cur_record_type).LISTS.(cur_listname) = cell([line_increment, 1]);
      case {"%f"}
        log_struct.(cur_record_type).LISTS.(cur_listname) = nan([line_increment, 1]);
      otherwise
        error(["ERROR: Unhandled listtype encountered: ", cur_listtype]);
    endswitch
  endfor
endif

% auto enlarge data structure
if (log_struct.(cur_record_type).last_valid_data_idx + 1) > size(log_struct.(cur_record_type).LISTS.LOG_DATETIME, 1)
  for i_list = 1 : length(log_struct.(cur_record_type).listnames)
    cur_listname = log_struct.(cur_record_type).listnames{i_list};
    cur_listtype = log_struct.(cur_record_type).listtypes{i_list};
    % put strings into cells and numeric data into proper double arrays
    switch cur_listtype
      case {"%s"}
        empty_list = cell([line_increment, 1]);
      case {"%f"}
        empty_list =  nan([line_increment, 1]);
      otherwise
        error(["ERROR: Unhandled listtype encountered: ", cur_listtype]);
    endswitch
    log_struct.(cur_record_type).LISTS.(cur_listname) = [log_struct.(cur_record_type).LISTS.(cur_listname); empty_list];
  endfor
  %disp("Growing DEBUG");
endif

cur_valid_data_idx = log_struct.(cur_record_type).last_valid_data_idx + 1;

% check sanity of lines...
orig_current_line = current_line;
delimiter_idx = strfind(current_line, delimiter_string);
if (ismember(cur_record_type, {'DEBUG', 'INFO', 'SHAPER'}))
  % if a line ends with a delimiter, do what?
  if (delimiter_idx(end) == length(current_line))
    switch log_struct.(cur_record_type).listtypes{end}
      case '%s'
        current_line = [current_line, 'EMPTY'];
      case '%f'
        current_line(end+1) = nan;
    endswitch

  endif
  % check for spurious delimiter characters in non DATA records (DEBUG/INFO/SHAPER)
  if length(delimiter_idx) > (length(log_struct.(cur_record_type).listtypes) -1)
    extra_delimiter_idx = delimiter_idx(length(log_struct.(cur_record_type).listtypes) : end);
    % replace by colon...
    current_line(extra_delimiter_idx) = ":";
  endif
endif
if (length(delimiter_idx) < length(log_struct.(cur_record_type).listnames) - 1)
  disp('WARN: incomplete line in logfile encountered...');
  cur_valid_data_idx = cur_valid_data_idx -1;
  return
endif

field_cell_array = textscan(current_line, log_struct.(cur_record_type).format_string, "Delimiter", delimiter_string);

if isempty(field_cell_array) || length(field_cell_array) < length(log_struct.(cur_record_type).listnames)
  disp('ERROR: This should not happen!');
endif

for i_list = 1 : length(log_struct.(cur_record_type).listnames)
  cur_listname = log_struct.(cur_record_type).listnames{i_list};
  log_struct.(cur_record_type).LISTS.(cur_listname)(cur_valid_data_idx) = field_cell_array{i_list};
endfor

% increase the pointer
log_struct.(cur_record_type).last_valid_data_idx = cur_valid_data_idx;
return
endfunction


function [ ] = fn_extract_DATA_names_types_format_from_HEADER( current_line, delimiter_string, string_field_identifier_list, HEADER_RECORD_name, DATA_RECORD_name )
global log_struct

% dissect the names
cell_array_of_field_names = textscan(current_line, '%s', 'Delimiter', delimiter_string);
cell_array_of_field_names = cell_array_of_field_names{1};
cell_array_of_field_names{1} = 'RECORD_TYPE'; % give this a better name than HEADER...

for i_field = 1 : length(cell_array_of_field_names)
  log_struct.(HEADER_RECORD_name).listnames{i_field} = sanitize_name_for_matlab(cell_array_of_field_names{i_field});
  log_struct.(DATA_RECORD_name).listnames{i_field} = sanitize_name_for_matlab(cell_array_of_field_names{i_field});

  cur_type_string = '%f'; % default to numeric
  for i_string_identifier = 1 : length(string_field_identifier_list)
    cur_string_identifier = string_field_identifier_list{i_string_identifier};
    if ~isempty(regexp(log_struct.(DATA_RECORD_name).listnames{i_field}, cur_string_identifier))
      cur_type_string = '%s';
    endif
  endfor

  %strcmp(log_struct.DATA.listnames{i_field}, 'TYPE')
  log_struct.(DATA_RECORD_name).listtypes{i_field} = cur_type_string;
end

log_struct.(DATA_RECORD_name).format_string = fn_compose_format_string(log_struct.(DATA_RECORD_name).listtypes);

return
endfunction


function [ format_string ] = fn_compose_format_string( type_list )
% construct a textscan type format string
format_string = '';

for i_field = 1 : length(type_list)
  format_string = [format_string, type_list{i_field}, ' '];
endfor

format_string = strtrim(format_string);

return
endfunction


function [ ] = fn_shrink_global_LISTS( record_type_list )
global log_struct
% remove pre-assigned but unfilled fields

for i_record_type = 1 : length(record_type_list)
  cur_record_type = record_type_list{i_record_type};
  if isfield(log_struct, cur_record_type) && isfield(log_struct.(cur_record_type), 'last_valid_data_idx')
    cur_num_valid_instances = log_struct.(cur_record_type).last_valid_data_idx;
    cur_listnames = log_struct.(cur_record_type).listnames;

    for i_list = 1 : length(log_struct.(cur_record_type).listnames)
      cur_listname = log_struct.(cur_record_type).listnames{i_list};
      log_struct.(cur_record_type).LISTS.(cur_listname) = log_struct.(cur_record_type).LISTS.(cur_listname)(1:cur_num_valid_instances);
    endfor
  endif
endfor
return
endfunction


function [ ret_val ] = write_out_figure(img_fh, outfile_fqn, verbosity_str, print_options_str)
%WRITE_OUT_FIGURE save the figure referenced by img_fh to outfile_fqn,
% using .ext of outfile_fqn to decide which image type to save as.
%   Detailed explanation goes here
% write out the data

if ~exist('verbosity_str', 'var')
  verbosity_str = 'verbose';
endif

% check whether the path exists, create if not...
[pathstr, name, img_type] = fileparts(outfile_fqn);
if isempty(dir(pathstr)),
  mkdir(pathstr);
endif

% deal with r2016a changes, needs revision
if (ismember(version('-release'), {'2016a', '2019a', '2019b'}))
  set(img_fh, 'PaperPositionMode', 'manual');
  if ~ismember(img_type, {'.png', '.tiff', '.tif'})
    print_options_str = '-bestfit';
  end
endif

if ~exist('print_options_str', 'var') || isempty(print_options_str)
  print_options_str = '';
else
  print_options_str = [', ''', print_options_str, ''''];
endif
resolution_str = ', ''-r600''';


device_str = [];

switch img_type(2:end)
  case 'pdf'
    % pdf in 7.3.0 is slightly buggy...
    %print(img_fh, '-dpdf', outfile_fqn);
    device_str = '-dpdf';
  case 'ps3'
    %print(img_fh, '-depsc2', outfile_fqn);
    device_str = '-depsc';
    print_options_str = '';
    outfile_fqn = [outfile_fqn, '.eps'];
  case {'ps', 'ps2'}
    %print(img_fh, '-depsc2', outfile_fqn);
    device_str = '-depsc2';
    print_options_str = '';
    outfile_fqn = [outfile_fqn, '.eps'];
  case {'tiff', 'tif'}
    % tiff creates a figure
    %print(img_fh, '-dtiff', outfile_fqn);
    device_str = '-dtiff';
  case 'png'
    % tiff creates a figure
    %print(img_fh, '-dpng', outfile_fqn);
    device_str = '-dpng';
    resolution_str = ', ''-r600''';
  case 'eps'
    %print(img_fh, '-depsc', '-r300', outfile_fqn);
    device_str = '-depsc';
  case 'svg'
    %print(img_fh, '-depsc', '-r300', outfile_fqn);
    device_str = '-dsvg';
  case 'fig'
    %sm: allows to save figures for further refinements
    saveas(img_fh, outfile_fqn, 'fig');
  otherwise
    % default to uncompressed images
    disp(['Image type: ', img_type, ' not handled yet...']);
endswitch

if ~isempty(device_str)
  device_str = [', ''', device_str, ''''];
  command_str = ['print(img_fh', device_str, print_options_str, resolution_str, ', outfile_fqn)'];
  eval(command_str);
endif

if strcmp(verbosity_str, 'verbose')
  if ~isnumeric(img_fh)
    disp(['INFO: Saved figure (', num2str(img_fh.Number), ') to: ', outfile_fqn]);	% >R2014b have structure figure handles
  else
    disp(['INFO: Saved figure (', num2str(img_fh), ') to: ', outfile_fqn]);			% older Matlab has numeric figure handles
  endif
endif

ret_val = 0;

return
endfunction


function [ output_rect ] = fn_set_figure_outputpos_and_size( figure_handle, left_edge_cm, bottom_edge_cm, rect_w, rect_h, fraction, PaperOrientation_string, Units_string )
%FN_SET_FIGURE_OUTPUTPOS_AND_SIZE Summary of this function goes here
%   Detailed explanation goes here
output_rect = [];

if ~ ishandle(figure_handle)
  error(['ERROR: First argument needs to be a figure handle...']);
end

cm2inch = 1/2.54;
fraction = 1;
output_rect = [left_edge_cm bottom_edge_cm rect_w rect_h] * cm2inch;	% left, bottom, width, height
set(figure_handle, 'Units', Units_string, 'Position', output_rect, 'PaperPosition', output_rect);
set(figure_handle, 'PaperSize', [rect_w+2*left_edge_cm*fraction rect_h+2*bottom_edge_cm*fraction] * cm2inch, 'PaperOrientation', PaperOrientation_string, 'PaperUnits', Units_string);
return
endfunction


function [ out_x_range, do_return ] = fn_sanitize_x_range( x_range, n_samples )
do_return = 0;
out_x_range = x_range;

if isempty(x_range)
  disp('INFO: Empty x_range specified, plotting all samples.');
  x_range = [1, n_samples];
  out_x_range = x_range;
endif

if (x_range(1) < 1)
  disp(['WARNING: Range start (', num2str(x_range(1)),') out of bounds, forcing to 1']);
  out_x_range(1) = 1;
  do_return = 0;
endif

if (x_range(2) > n_samples)
  disp(['WARNING: Range end (', num2str(x_range(2)), ') out of bounds, forcing to number of samples (', num2str(n_samples),').']);
  out_x_range(2) = n_samples;
  do_return = 0;
endif

if (out_x_range(1) > out_x_range(2))
  disp('WARNING: Requested range start is larger than range end, please fix...');
  do_return = 1;
endif

if (out_x_range(1) == out_x_range(2))
  disp('WARNING: Requested range is of size 1, please fix...');
  do_return = 1;
endif


return
endfunction


function [ out_x_range_sec, do_return ] = fn_sanitize_x_range_sec( x_range_sec, first_sample_timestamp, last_sample_timestamp )
do_return = 0;
out_x_range_sec = x_range_sec;

% get reasonable values for the x_range in seconds to display
first_sample_relative_timestamp = first_sample_timestamp - first_sample_timestamp;
last_sample_relative_timestamp = last_sample_timestamp - first_sample_timestamp;

if isempty(x_range_sec)
  disp(['INFO: Empty x_range_sec specified, plotting the whole sample timestamp range (', num2str(first_sample_relative_timestamp), ' - ', num2str(last_sample_relative_timestamp), ').']);
  out_x_range_sec = [first_sample_relative_timestamp, last_sample_relative_timestamp];
  return
endif

if (x_range_sec(1) > x_range_sec(2))
  % just change the order and perform the rest of the sanity checks
  disp('WARNING: x_range_sec(1) > x_range_sec(2), inverting to make some sense, please check');
  out_x_range_sec = [out_x_range_sec(2), out_x_range_sec(1)];
endif

% just adjust the start value
if x_range_sec(1) < first_sample_relative_timestamp
  out_x_range_sec(1) = first_sample_relative_timestamp;
endif

% just adjust the end value
if x_range_sec(2) > last_sample_relative_timestamp
  out_x_range_sec(2) = last_sample_relative_timestamp;
endif

if (out_x_range_sec(1) == out_x_range_sec(2))
  disp('WARNING: x_range_sec(1) == x_range_sec(2), please correct');
  do_return = 1;
endif

endfunction


function [ x_range ] = fn_get_range_indices_from_range_timestamps( x_range_sec_absolute, timestamp_list )
% x_range_sec_absolute needs to be in absolute timestamps, not relative to log file start
% find the index of the first timestamp equal or larger than x_range_sec(1)
x_range(1) = find(timestamp_list >= x_range_sec_absolute(1), 1, 'first');
% find the index of the last timestamp equal or smaller than x_range_sec(2)
x_range(2) = find(timestamp_list <= x_range_sec_absolute(2), 1, 'last');
endfunction


function [ ax_h, legend_list ] = fn_plot_CDF_cell( ax_h, unique_reflector_list, CDF_x_vec, color_by_reflector_array, cumulative_range_percent, ...
xlabel_string, ylabel_string, title_string, ...
set_name_list, n_sample_per_reflector_list, cur_data_XDF_list, linestyle_list, linewidth_list, distribution_string)

legend_font_size = 6;

%	xlabel_string = 'delay [ms]';
%	ylabel_string = 'cumulative density [%]';
%	title_string = 'RTT, high versus low load';
%	set_name_list = {': low load', ': high load'}
%	n_sample_per_reflector_list = {};
%	cur_data_XDF_list = {RTT_LowLoad_sample_delay_CDF_by_reflector_array, RTT_HighLoad_sample_delay_CDF_by_reflector_array}
%	linestyle_list = {'-', ':'};
%	linewidth_list = {line_width, line_width};
n_unique_reflectors = length(unique_reflector_list);
n_sets = length(set_name_list);
cur_x_low_quantile_idx = nan([n_unique_reflectors, n_sets]);
cur_x_high_quantile_idx = nan([n_unique_reflectors, n_sets]);
legend_list = {};
hold on
for i_reflector = 1:n_unique_reflectors
  cur_reflector_color = color_by_reflector_array(i_reflector, :);

  for i_set = 1 : n_sets
    cur_set_name = set_name_list{i_set};
    cur_n_sample_per_reflector = n_sample_per_reflector_list{i_set};
    cur_n_sample = cur_n_sample_per_reflector(i_reflector);
    cur_data_XDF = cur_data_XDF_list{i_set};
    cur_linestle = linestyle_list{i_set};
    cur_linewidth = linewidth_list{i_set};

    legend_list{end+1} = [unique_reflector_list{i_reflector}, [cur_set_name, ':(N:', num2str(cur_n_sample),')']];
    cur_data = 100 * cur_data_XDF(i_reflector, :);
    plot(ax_h, CDF_x_vec, (cur_data), 'Color', cur_reflector_color, 'Linestyle', cur_linestle, 'LineWidth', cur_linewidth);

    cur_data_CDF = cur_data;
    switch distribution_string
      case {'pdf', 'PDF'}
        cur_data_CDF = cumsum(cur_data);
        cur_data_CDF = 100 * cur_data_CDF / max(cur_data_CDF);
    endswitch
    % find high and low x values
    if ~isempty(find(cur_data_CDF >= cumulative_range_percent(1), 1, 'first'))
      cur_x_low_quantile_idx(i_reflector, i_set) = find(cur_data_CDF >= cumulative_range_percent(1), 1, 'first');
    endif
    if ~isempty(find(cur_data_CDF <= cumulative_range_percent(2), 1, 'last'))
      cur_x_high_quantile_idx(i_reflector, i_set) = find(cur_data_CDF <= cumulative_range_percent(2), 1, 'last');
    endif
  endfor
endfor
hold off
set(ax_h, 'XLim', [CDF_x_vec(min(cur_x_low_quantile_idx(:))), CDF_x_vec(max(cur_x_high_quantile_idx(:)))]);
% for PDFs use auto scaling, these are scaled to unity area, so 0-100% does not make much sense for PDFs
if strcmp(distribution_string, 'CDF')
  set(ax_h, 'YLim', [0, 100]);
endif
xlabel(ax_h, xlabel_string);
ylabel(ax_h, ylabel_string)
title(ax_h, title_string);
try
  if strcmp(graphics_toolkit, 'gnuplot')
    legend(legend_list, 'Interpreter', 'none', 'box', 'off', 'location', 'eastoutside', 'FontSize', legend_font_size);
  else
    legend(legend_list, 'Interpreter', 'none', 'numcolumns', 1, 'box', 'off', 'location', 'eastoutside', 'FontSize', legend_font_size);
  end
catch
  disp(['Triggered']);
  legend(legend_list, 'Interpreter', 'none', 'box', 'off', 'FontSize', legend_font_size);
end_try_catch

return
endfunction


function [ load_struct ] = fn_get_samples_by_load(DATA_LISTS_struct, method_string, direction_list, data_field_name_list, LowLoad_threshold, HighLoad_threshold);
load_struct = struct();
% direction_list = {'UL', 'DL'};
% data_field_name_list = {'UL_LOAD_PERCENT', 'DL_LOAD_PERCENT'};
switch method_string
  case 'LOAD_PERCENT'
    % just take the load percentage as calculated by autorate
    for i_direction = 1 : length(direction_list)
      cur_direction_string = direction_list{i_direction};
      cur_data_fieldname = data_field_name_list{i_direction};
      load_struct.(cur_direction_string).AnyLoad = find(ones(size(DATA_LISTS_struct.(cur_data_fieldname))));
      load_struct.(cur_direction_string).LowLoad = find(DATA_LISTS_struct.(cur_data_fieldname) <= LowLoad_threshold);
      load_struct.(cur_direction_string).HighLoad = find(DATA_LISTS_struct.(cur_data_fieldname) >= HighLoad_threshold);
    endfor


    load_struct.ULorDL.AnyLoad = [];
    load_struct.ULorDL.LowLoad = [];
    load_struct.ULorDL.HighLoad = [];
    % both UL and DL
    load_struct.ULandDL.AnyLoad = [];
    load_struct.ULandDL.LowLoad = [];
    load_struct.ULandDL.HighLoad = [];

    if isfield(load_struct, 'UL') && isfield(load_struct, 'DL')
      % either DL or UL
      load_struct.ULorDL.AnyLoad = load_struct.UL.AnyLoad;
      load_struct.ULorDL.LowLoad = union(load_struct.UL.LowLoad, load_struct.DL.LowLoad);
      load_struct.ULorDL.HighLoad = union(load_struct.UL.HighLoad, load_struct.DL.HighLoad);
      % both UL and DL
      load_struct.ULandDL.AnyLoad = load_struct.UL.AnyLoad;
      load_struct.ULandDL.LowLoad = intersect(load_struct.UL.LowLoad, load_struct.DL.LowLoad);
      load_struct.ULandDL.HighLoad = intersect(load_struct.UL.HighLoad, load_struct.DL.HighLoad);
    endif
  otherwise
    error(['ERROR: Unkown method_string (', method_string, ') encountered. ']);
endswitch
return
endfunction


function [ delay_struct, CDF_x_vec, unique_reflector_list ] = fn_get_XDF_by_load(method_string, delay_type_string, UL_OWD_sample_list, DL_OWD_sample_list, data_scale_factor, ...
calc_range_ms, step_size_ms, REFLECTOR_by_sample_list, sample_idx_by_load, DATA_delays_x_idx)
% method_string = 'CDF';
% delay_type_string = 'RAW';
delay_struct = struct();

% the time resolution
CDF_x_vec = (calc_range_ms(1):step_size_ms:calc_range_ms(end));
unique_reflector_list = unique(REFLECTOR_by_sample_list);
n_unique_reflectors = length(unique_reflector_list);

delay_struct.CDF_x_vec = CDF_x_vec;
delay_struct.unique_reflector_list = unique_reflector_list;


% the next needs checking for true OWDs and RTTs
RTT_sample_list = UL_OWD_sample_list + DL_OWD_sample_list;

delay.UL_OWD = UL_OWD_sample_list;
delay.DL_OWD = DL_OWD_sample_list;
delay.RTT = RTT_sample_list;
delay_measure_list = fieldnames(delay);

load_direction_list = fieldnames(sample_idx_by_load);
load_condition_list = fieldnames(sample_idx_by_load.UL);


% now construct all combinations of delay_measure, load_direction and load_condition
% and generate the respective sample list and then calculate the method_string for all reflectors
% report the method, n, and idx? as structure fields

% pre-allocate data structures
for i_measure = 1 : length(delay_measure_list)
  cur_delay_measure_name = delay_measure_list{i_measure};
  cur_delay_data = delay.(cur_delay_measure_name);
  for i_load_direction = 1 : length(load_direction_list)
    cur_load_direction = load_direction_list{i_load_direction};
    for i_load_condition = 1 : length(load_condition_list);
      cur_load_condition = load_condition_list{i_load_condition};
      % allocate the data structures
      delay_struct.(cur_delay_measure_name).(cur_load_direction).(cur_load_condition).data = nan([n_unique_reflectors, length(CDF_x_vec)]);
      delay_struct.(cur_delay_measure_name).(cur_load_direction).(cur_load_condition).n = zeros([n_unique_reflectors, 1]);

      % now perform the calculation
      for i_reflector = 1:n_unique_reflectors
        cur_reflector = unique_reflector_list{i_reflector};
        cur_reflector_sample_idx = find(ismember(REFLECTOR_by_sample_list, {cur_reflector}));
        cur_All_sample_idx = intersect(DATA_delays_x_idx, cur_reflector_sample_idx);

        cur_load_directon_load_condition_sample_idx = intersect(cur_All_sample_idx, sample_idx_by_load.(cur_load_direction).(cur_load_condition));

        if ~isempty(cur_load_directon_load_condition_sample_idx)
          switch method_string
            case {'cdf', 'CDF'}
              delay_struct.(cur_delay_measure_name).(cur_load_direction).(cur_load_condition).data(i_reflector, :) = empirical_cdf(CDF_x_vec, (cur_delay_data(cur_load_directon_load_condition_sample_idx) * data_scale_factor));
            case {'pdf', 'PDF'}
              delay_struct.(cur_delay_measure_name).(cur_load_direction).(cur_load_condition).data(i_reflector, :) = empirical_pdf(CDF_x_vec, (cur_delay_data(cur_load_directon_load_condition_sample_idx) * data_scale_factor));
          endswitch
          delay_struct.(cur_delay_measure_name).(cur_load_direction).(cur_load_condition).n(i_reflector) = length(cur_load_directon_load_condition_sample_idx);
        endif
      endfor
    endfor
  endfor
endfor

return
endfunction


function [ autorate_CDF_fh ] = fn_plot_CDF_by_measure_and_load_condition( distribution_string, figure_opts, data_struct, cumulative_range_percent, xlabel_string, ylabel_string, cur_plot_FQN )

data = data_struct;
CDF_x_vec = data_struct.CDF_x_vec;
unique_reflector_list = data_struct.unique_reflector_list;
n_unique_reflectors = length(unique_reflector_list);

autorate_CDF_fh = figure('Name', 'CAKE-autorate log: delay CDFs', 'visible', figure_opts.figure_visibility_string);
[ output_rect ] = fn_set_figure_outputpos_and_size( autorate_CDF_fh, 0.2, 0.2, 45, 15, 1, 'landscape', 'centimeters' );

% do a 3 by 2 matrix:
% upper row col1: RTT all samples
%			col2: DL all samples
%			col3: UL all samples
% lower row col1: RTT low vs high load
%			col2: DL low vs high load
%			col3: UL low vs high load
% common properties
% get unique colors but avoid black and white
tmp_color_by_reflector_list = cubehelix(n_unique_reflectors + 2);
color_by_reflector_array = tmp_color_by_reflector_list(2:end-1, :);

cur_sph = subplot(2, 3, 1);
[ cur_sph, legend_list ] = fn_plot_CDF_cell(cur_sph, unique_reflector_list, CDF_x_vec, color_by_reflector_array, cumulative_range_percent, ...
xlabel_string, ylabel_string, 'RTT, all samples', ...
{''}, {data.RTT.ULorDL.AnyLoad.n}, {data.RTT.ULorDL.AnyLoad.data}, {'-'}, {figure_opts.line_width}, distribution_string);

cur_sph = subplot(2, 3, 2);
[ cur_sph, legend_list ] = fn_plot_CDF_cell(cur_sph, unique_reflector_list, CDF_x_vec, color_by_reflector_array, cumulative_range_percent, ...
xlabel_string, ylabel_string, 'Download OWD, all samples', ...
{''}, {data.DL_OWD.DL.AnyLoad.n}, {data.DL_OWD.DL.AnyLoad.data}, {'-'}, {figure_opts.line_width}, distribution_string);

cur_sph = subplot(2, 3, 3);
[ cur_sph, legend_list ] = fn_plot_CDF_cell(cur_sph, unique_reflector_list, CDF_x_vec, color_by_reflector_array, cumulative_range_percent, ...
xlabel_string, ylabel_string, 'Upload OWD, all samples', ...
{''}, {data.UL_OWD.UL.AnyLoad.n}, {data.UL_OWD.UL.AnyLoad.data}, {'-'}, {figure_opts.line_width}, distribution_string);

cur_sph = subplot(2, 3, 4);
[ cur_sph, legend_list ] = fn_plot_CDF_cell(cur_sph, unique_reflector_list, CDF_x_vec, color_by_reflector_array, cumulative_range_percent, ...
xlabel_string, ylabel_string, 'RTT, high versus low load', ...
{': low', ': high'}, {data.RTT.ULorDL.LowLoad.n, data.RTT.ULorDL.HighLoad.n}, {data.RTT.ULorDL.LowLoad.data, data.RTT.ULorDL.HighLoad.data}, {'-', ':'}, {figure_opts.line_width, figure_opts.line_width}, distribution_string);

cur_sph = subplot(2, 3, 5);
[ cur_sph, legend_list ] = fn_plot_CDF_cell(cur_sph, unique_reflector_list, CDF_x_vec, color_by_reflector_array, cumulative_range_percent, ...
xlabel_string, ylabel_string, 'Download OWD, high versus low load', ...
{': low', ': high'}, {data.DL_OWD.DL.LowLoad.n, data.DL_OWD.DL.HighLoad.n}, {data.DL_OWD.DL.LowLoad.data, data.DL_OWD.DL.HighLoad.data}, {'-', ':'}, {figure_opts.line_width, figure_opts.line_width}, distribution_string);

cur_sph = subplot(2, 3, 6);
[ cur_sph, legend_list ] = fn_plot_CDF_cell(cur_sph, unique_reflector_list, CDF_x_vec, color_by_reflector_array, cumulative_range_percent, ...
xlabel_string, ylabel_string, 'Upload OWD, high versus low load', ...
{': low', ': high'}, {data.UL_OWD.UL.LowLoad.n, data.UL_OWD.UL.HighLoad.n}, {data.UL_OWD.UL.LowLoad.data, data.UL_OWD.UL.HighLoad.data}, {'-', ':'}, {figure_opts.line_width, figure_opts.line_width}, distribution_string);


disp(['INFO: Writing plot as: ', cur_plot_FQN]);
write_out_figure(autorate_CDF_fh, cur_plot_FQN, [], []);

return
endfunction


function [] = fn_propose_delay_thresholds( delta_CDF, calc_range_ms )
% report the delay of the maximal 95%, 99%, 99.99% y-values over all reflectors
% for

delay.DL = delta_CDF.DL_OWD.ULandDL.LowLoad.data;
delay.UL = delta_CDF.UL_OWD.ULandDL.LowLoad.data;
n.DL = delta_CDF.DL_OWD.ULandDL.LowLoad.n;
n.UL = delta_CDF.UL_OWD.ULandDL.LowLoad.n;
delay_data_list = fieldnames(delay);

quantiles_to_report_list = [95, 99, 99.5, 99.9, 99.95, 99.99, 99.999];
n_bins = size(delay.UL, 2);
CDF_step_size_ms = (calc_range_ms(2) - calc_range_ms(1)) / (n_bins - 1);
% here we want the full calculated range if it exists...
CDF_x_vec = (calc_range_ms(1):CDF_step_size_ms:calc_range_ms(2));

unique_reflector_list = delta_CDF.unique_reflector_list;
n_unique_reflectors = length(unique_reflector_list);

cur_x_quantile_to_report_id = nan([length(quantiles_to_report_list), n_unique_reflectors]);

disp('Samples per reflector:');
for i_reflector = 1:n_unique_reflectors
  disp(['ReflectorID: ', unique_reflector_list{i_reflector}, '; N: ', num2str(n.UL(i_reflector))]); % for ULandDL both UL and DL will have the same number of samples
endfor

for i_delay = 1 : length(delay_data_list)
  cur_delay = delay_data_list{i_delay};
  cur_data_CDF = delay.(cur_delay) * 100;

  for i_quantile = 1 : length(quantiles_to_report_list)
    cur_quantile = quantiles_to_report_list(i_quantile);
    for i_reflector = 1:n_unique_reflectors
      cur_data_CDF_per_reflector = cur_data_CDF(i_reflector, :);
      % find the requested quantiles
      cur_x_quantile = find(cur_data_CDF_per_reflector <= cur_quantile, 1, 'last');
      if ~isempty(cur_x_quantile)
        cur_x_quantile_to_report_id(i_quantile, i_reflector) = cur_x_quantile;
      endif
    endfor
    max_delay_for_quantile = CDF_x_vec(max(cur_x_quantile_to_report_id(i_quantile, :)));
    disp([cur_delay, ': maximum ', num2str(cur_quantile, '%3.3f'), '%-ile delta delay over all ', num2str(n_unique_reflectors), ' reflectors: ', num2str(max_delay_for_quantile, '%4.3f'), ' ms.']);
  endfor
endfor
return
endfunction

