function [ autorate_log ] = fn_parse_autorate_log( log_FQN )
	% This program is free software; you can redistribute it and/or modify
	% it under the terms of the GNU General Public License version 2 as
	% published by the Free Software Foundation.
	%
	%       Copyright (C) 2022 Sebastian Moeller


	% load the data file
	[ autorate_log, log_FQN ] = fn_parse_autorate_logfile( [] );
	% dissect the fully qualified name
	[log_dir, log_name, log_ext ] = fileparts(log_FQN);

	align_rate_and_delay_zeros = 1; % so that delay and rate 0s are aligned, not implemented yet
	output_format_extension = '.pdf';
	line_width = 1.0;


	% set up the plots
	rates.fields_to_plot_list = {'CAKE_DL_RATE_KBPS', 'CAKE_UL_RATE_KBPS', 'DL_ACHIEVED_RATE_KBPS', 'UL_ACHIEVED_RATE_KBPS'};
	rates.color_list = {[241,182,218]/254, [184,225,134]/254, [208,28,139]/254, [77,172,38]/254};
	rates.linestyle_list = {'-', '-', '-', '-'};
	rates.sign_list = {1, 1, 1, 1};
	rates.sign_list = {1, -1, 1, -1};
	rates.scale_factor = 1/1000;
	delays.fields_to_plot_list = {'DL_OWD_BASELINE', 'UL_OWD_BASELINE', 'DL_OWD_US', 'UL_OWD_US', 'DL_OWD_DELTA_US', 'UL_OWD_DELTA_US', 'ADJ_DELAY_THR', 'ADJ_DELAY_THR'};
	delays.color_list = {[140, 81, 10]/254, [1, 102, 94]/254, [216, 179, 101]/254, [90, 180, 172]/254, [246, 232, 195]/254, [199, 234, 229]/254, [1.0, 0.0, 0.0], [1.0, 0.0, 0.0]};
	delays.linestyle_list = {'--', '--', '--', '--', '-', '-', '-', '-'};
	delays.sign_list = {-1, -1, -1, -1, 1, 1, 1, 1};
	delays.sign_list = {1, -1, 1, -1, 1, -1, 1, -1};
	delays.scale_factor = 1/1000;
	x_range = [20, length(autorate_log.DATA.LISTS.RECORD_TYPE)];
	x_vec = (x_range(1):1:x_range(end));

	% for testing align_rate_and_delay_zeros
%	autorate_log.DATA.LISTS.DL_OWD_US = 10*autorate_log.DATA.LISTS.DL_OWD_US;
	% for testing align_rate_and_delay_zeros
%	autorate_log.DATA.LISTS.UL_OWD_US = 10*autorate_log.DATA.LISTS.UL_OWD_US;


	% plot something
	autorate_fh = figure('Name', 'CAKE-autorate log file display');
	[ output_rect ] = fn_set_figure_outputpos_and_size( autorate_fh, 1, 1, 27, 19, 1, 'landscape', 'centimeters' );


	cur_sph = subplot(2, 2, [1 2]);

	%plot data on both axes
	% use this as dummy to create the axis:
	cur_scaled_data_rates = autorate_log.DATA.LISTS.(rates.fields_to_plot_list{1})(x_range(1):x_range(2)) * rates.scale_factor;
	cur_scaled_data_delays = autorate_log.DATA.LISTS.(delays.fields_to_plot_list{1})(x_range(1):x_range(2)) * delays.scale_factor;

	[AX H1 H2] = plotyy(x_vec, (rates.sign_list{1} * cur_scaled_data_rates)', x_vec, (delays.sign_list{1} * cur_scaled_data_delays)', 'plot');
	%hold both axes
	hold(AX(1));
	legend_list = {};
	for i_field = 1 : length(rates.fields_to_plot_list)
		legend_list{end+1} = rates.fields_to_plot_list{i_field};
		cur_scaled_data = autorate_log.DATA.LISTS.(rates.fields_to_plot_list{i_field})(x_range(1):x_range(2)) * rates.scale_factor;
		plot(AX(1), x_vec, (rates.sign_list{i_field} * cur_scaled_data)', 'Color', rates.color_list{i_field}, 'Linestyle', rates.linestyle_list{i_field}, 'LineWidth', line_width);
	endfor
	%legend(legend_list, 'Interpreter', 'none');
	hold off
	xlabel(AX(1),'autorate samples');
	ylabel(AX(1), 'Rate [Mbps]');


	hold(AX(2));
	for i_field = 1 : length(delays.fields_to_plot_list)
		legend_list{end+1} = delays.fields_to_plot_list{i_field};
		cur_scaled_data = autorate_log.DATA.LISTS.(delays.fields_to_plot_list{i_field})(x_range(1):x_range(2)) * delays.scale_factor;
		plot(AX(2), x_vec, (delays.sign_list{i_field} * cur_scaled_data)', 'Color', delays.color_list{i_field}, 'Linestyle', delays.linestyle_list{i_field}, 'LineWidth', line_width);
	endfor
	%legend(legend_list, 'Interpreter', 'none');
	hold off
	xlabel('autorate samples');
	ylabel('Delay [milliseconds]');

	% make sure the zeros of both axes align
	if (align_rate_and_delay_zeros)
		ylim_rates = get(AX(1), 'YLim');
		ylim_delays = get(AX(2), 'YLim');

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
		set(AX(2), 'YLim', [new_lower_y_delay, new_upper_y_delay]);
	endif


	cur_sph = subplot(2, 2, 3);
	% rates
	hold on
	legend_list = {};
	for i_field = 1 : length(rates.fields_to_plot_list)
		legend_list{end+1} = rates.fields_to_plot_list{i_field};
		cur_scaled_data = autorate_log.DATA.LISTS.(rates.fields_to_plot_list{i_field})(x_range(1):x_range(2)) * rates.scale_factor;
		plot(x_vec, (rates.sign_list{i_field} * cur_scaled_data)', 'Color', rates.color_list{i_field}, 'Linestyle', rates.linestyle_list{i_field}, 'LineWidth', line_width);
	endfor
	legend(legend_list, 'Interpreter', 'none', 'numcolumns', 2, 'box', 'off', 'location', 'northoutside', 'FontSize', 7);
	hold off
	xlabel('autorate samples');
	ylabel('Rate [Mbps]');


	cur_sph = subplot(2, 2, 4);
	% delays
	hold on
	legend_list = {};
	for i_field = 1 : length(delays.fields_to_plot_list)
		legend_list{end+1} = delays.fields_to_plot_list{i_field};
		cur_scaled_data = autorate_log.DATA.LISTS.(delays.fields_to_plot_list{i_field})(x_range(1):x_range(2)) * delays.scale_factor;
		plot(x_vec, (delays.sign_list{i_field} * cur_scaled_data)', 'Color', delays.color_list{i_field}, 'Linestyle', delays.linestyle_list{i_field}, 'LineWidth', line_width);
	endfor
	legend(legend_list, 'Interpreter', 'none', 'numcolumns', 3, 'box', 'off', 'location', 'northoutside', 'FontSize', 7);
	hold off
	xlabel('autorate samples');
	ylabel('Delay [milliseconds]');


	write_out_figure(autorate_fh, fullfile(log_dir, [log_name, output_format_extension]), [], []);



	return
endfunction

function [ autorate_log, log_FQN ] = fn_parse_autorate_logfile( log_FQN, command_string )

	%if ~(isoctave)
	dbstop if error;
	%end

	timestamps.(mfilename).start = tic;
	fq_mfilename = mfilename('fullpath');
	mfilepath = fileparts(fq_mfilename);

	disp(mfilepath);

	% variables
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
	log_struct.INFO =[];

	%TODO: merge current and old log file if they can be found...

	if ~exist('log_FQN', 'var') || isempty(log_FQN)
		% open a ui file picker
		%[log_name, log_dir, fld_idx] = uigetfile("*.log", "Select one or more autorate log files:", "MultiSelect", "on");
		[log_name, log_dir, fld_idx] = uigetfile("*.log", "Select one or more autorate log files:");
		log_FQN = fullfile(log_dir, log_name);
	endif

	if ~exist('command_string', 'var') || isempty(command_string)
		command_string = 'load_existing';
	endif

	% dissect the fully qualified name
	[log_dir, log_name, log_ext ] = fileparts(log_FQN);

	if exist(fullfile(log_dir, [log_name, '.mat']), 'file') && strcmp(command_string, 'load_existing')
		disp(['Found already parsed log file (', fullfile(log_dir, [log_name, '.mat']), '), loading...']);
		load(fullfile(log_dir, [log_name, '.mat']));
		return
	endif

	% now read the file line by line and steer each line into the correct structure.
	% if this would not be intereaved things would be easier
	log_fd = fopen(log_FQN);
	if log_fd == -1
		error(["Could not open: ", log_FQN]);
	endif

	cur_record_type = "";
	% get started
	while (!feof(log_fd) )
		% get the next line
		current_line = fgetl(log_fd);

		cur_record_type = fn_get_record_type_4_line(current_line, delimiter_string, string_field_identifier_list);
		fn_parse_current_line(cur_record_type, current_line, delimiter_string, line_increment);

		%disp(current_line)
	endwhile

	% clean-up
	fclose(log_fd);


	% shrink global datastructures
	fn_shrink_global_LISTS({"DEBUG", "INFO", "DATA", "SHAPER"});

	% ready for export and
	autorate_log = log_struct;

	% save autorate_log as mat file...
	disp(['Saving parsed data fie as: ', fullfile(log_dir, [log_name, '.mat'])]);
	save(fullfile(log_dir, [log_name, '.mat']), 'autorate_log', '-7');


	% verbose exit
	timestamps.(mfilename).end = toc(timestamps.(mfilename).start);
	disp([mfilename, ' took: ', num2str(timestamps.(mfilename).end), ' seconds.']);

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
		case {"HEADE"}
			cur_record_type = "HEADER";
		case {"DATA;"}
			cur_record_type = "DATA";
		case {"SHAPE"}
			cur_record_type = "SHAPER";
		case {"INFO;"}
			cur_record_type = "INFO";
		otherwise
			disp(["Unhandled type identifier encountered: ", current_line(1:4)]);
			error("Not handled yet, bailing out...");
	endswitch

	% define the parsing strings
	switch cur_record_type
		case {"DEBUG"}
			if ~isfield(log_struct.DEBUG, 'listtypes') || isempty(log_struct.DEBUG.listtypes)
				log_struct.DEBUG.listnames = {"TYPE", "LOG_DATETIME", "LOG_TIMESTAMP", "MESSAGE"};#
				log_struct.DEBUG.listtypes = {"%s", "%s", "%f", "%s"};
				log_struct.DEBUG.format_string = fn_compose_format_string(log_struct.DEBUG.listtypes);
			endif
		case {"HEADER"}
			if ~isfield(log_struct.HEADER, 'listtypes') || isempty(log_struct.DEBUG.listtypes)
				fn_extract_DATA_names_types_format_from_HEADER(current_line, delimiter_string, string_field_identifier_list);
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
		otherwise
			%disp(["Unhandled record_type  encountered: ", cur_record_type]);
			%error("Not handled yet, bailing out...");
	endswitch

	return
endfunction

function [ ] = fn_parse_current_line( cur_record_type, current_line, delimiter_string, line_increment)
	global log_struct

	if ~ismember(cur_record_type, {'INFO', 'SHAPER', 'DEBUG', 'DATA'}) % {'DEBUG', 'INFO', 'SJHAPER'}
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
					error(["Unhandled listtype encountered: ", cur_listtype]);
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
					error(["Unhandled listtype encountered: ", cur_listtype]);
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
		if length(delimiter_idx) > (length(log_struct.(cur_record_type).listtypes) -1) ...
			extra_delimiter_idx = delimiter_idx(length(log_struct.(cur_record_type).listtypes) : end);
			% replace by colon...
			current_line(extra_delimiter_idx) = ":";
		endif
	endif
	field_cell_array = textscan(current_line, log_struct.(cur_record_type).format_string, "Delimiter", delimiter_string);

	for i_list = 1 : length(log_struct.(cur_record_type).listnames)
		cur_listname = log_struct.(cur_record_type).listnames{i_list};
		log_struct.(cur_record_type).LISTS.(cur_listname)(cur_valid_data_idx) = field_cell_array{i_list};
	endfor


	% increase the pointer
	log_struct.(cur_record_type).last_valid_data_idx = cur_valid_data_idx;
	return
endfunction

function [ ] = fn_extract_DATA_names_types_format_from_HEADER( current_line, delimiter_string, string_field_identifier_list )
	global log_struct

	% dissect the names
	cell_array_of_field_names = textscan(current_line, '%s', 'Delimiter', delimiter_string);
	cell_array_of_field_names = cell_array_of_field_names{1};
	cell_array_of_field_names{1} = 'RECORD_TYPE'; % give this a better name than HEADER...

	for i_field = 1 : length(cell_array_of_field_names)
		log_struct.HEADER.listnames{i_field} = sanitize_name_for_matlab(cell_array_of_field_names{i_field});
		log_struct.DATA.listnames{i_field} = sanitize_name_for_matlab(cell_array_of_field_names{i_field});

		cur_type_string = '%f'; % default to numeric
		for i_string_identifier = 1 : length(string_field_identifier_list)
			cur_string_identifier = string_field_identifier_list{i_string_identifier};
			if ~isempty(regexp(log_struct.DATA.listnames{i_field}, cur_string_identifier))
				cur_type_string = '%s';
			endif
		endfor

		%strcmp(log_struct.DATA.listnames{i_field}, 'TYPE')
		log_struct.DATA.listtypes{i_field} = cur_type_string;
	end

	log_struct.DATA.format_string = fn_compose_format_string(log_struct.DATA.listtypes);

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
			resolution_str = ', ''-r1200''';
		case 'eps'
			%print(img_fh, '-depsc', '-r300', outfile_fqn);
			device_str = '-depsc';
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
			disp(['Saved figure (', num2str(img_fh.Number), ') to: ', outfile_fqn]);	% >R2014b have structure figure handles
		else
			disp(['Saved figure (', num2str(img_fh), ') to: ', outfile_fqn]);			% older Matlab has numeric figure handles
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
		error(['First argument needs to be a figure handle...']);
	end


	cm2inch = 1/2.54;
	fraction = 1;
	output_rect = [left_edge_cm bottom_edge_cm rect_w rect_h] * cm2inch;	% left, bottom, width, height
	set(figure_handle, 'Units', Units_string, 'Position', output_rect, 'PaperPosition', output_rect);
	set(figure_handle, 'PaperSize', [rect_w+2*left_edge_cm*fraction rect_h+2*bottom_edge_cm*fraction] * cm2inch, 'PaperOrientation', PaperOrientation_string, 'PaperUnits', Units_string);


	return
end

