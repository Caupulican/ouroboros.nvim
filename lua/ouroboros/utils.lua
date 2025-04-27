local config = require("ouroboros.config")

local M = {}

-- logs info to :messages if ouroboros_debug is true
function M.log(v)
	if vim.g.ouroboros_debug ~= 0 then
		print(v)
	end
end

-- quick and dirty means of doing a ternary in Lua
function M.ternary(condition, T, F)
	if condition then
		return T
	else
		return F
	end
end

-- Returns the Path, Filename, and Extension as 3 values
function M.split_filename(file)
	-- captures path, filename (without trailing dot), and extension
	local path, filename, extension = string.match(file, "(.-)([^\\/]-)([^\\/%.]+)$")
	-- remove the trailing dot from filename
	filename = filename:sub(1, -2)
	return path, filename, extension
end

-- Splits a path into its directories
function M.split_path_into_directories(path)
	local dirs = {}
	local sep = package.config:sub(1, 1) -- directory separator for current OS
	for dir in path:gmatch("([^" .. sep .. "]+)") do
		table.insert(dirs, dir)
	end
	return dirs
end

-- Counts how many trailing directory components match between two paths
function M.calculate_similarity(path1, path2)
	local dirs1 = M.split_path_into_directories(path1)
	local dirs2 = M.split_path_into_directories(path2)
	local count = 0
	local length1 = #dirs1
	local length2 = #dirs2
	for i = 0, math.min(length1, length2) - 1 do
		if dirs1[length1 - i] == dirs2[length2 - i] then
			count = count + 1
		end
	end
	M.log(string.format("Path 1: %s, Path 2: %s, Score %d", path1, path2, count))
	return count
end

-- Try switching to a visible window whose buffer matches both name and directory
function M.switch_to_open_file_if_possible(file_path)
	if not config.settings.switch_to_open_pane_if_possible then
		return false
	end
	local current_file = vim.api.nvim_buf_get_name(0)
	local current_dir = vim.fn.fnamemodify(current_file, ":h")
	local abs_target
	if file_path:match("^/") or file_path:match("^~") then
		abs_target = vim.fn.fnamemodify(file_path, ":p")
	else
		abs_target = vim.fn.fnamemodify(current_dir .. "/" .. file_path, ":p")
	end

	-- First check for exact path match
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p")
		if buf_path and buf_path ~= "" then
			if buf_path == abs_target then
				vim.api.nvim_set_current_win(win)
				M.log("Found exact match in window: " .. buf_path)
				return true
			end
		end
	end

	-- If exact match not found, fall back to directory + name matching
	local target_dir = vim.fn.fnamemodify(abs_target, ":h")
	local target_name = vim.fn.fnamemodify(abs_target, ":t")
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p")
		if buf_path and buf_path ~= "" then
			local buf_dir = vim.fn.fnamemodify(buf_path, ":h")
			local buf_name = vim.fn.fnamemodify(buf_path, ":t")
			if buf_dir == target_dir and buf_name == target_name then
				vim.api.nvim_set_current_win(win)
				M.log("Found dir+name match in window: " .. buf_path)
				return true
			end
		end
	end
	return false
end

-- Finds the extension with the highest preference score
function M.find_highest_preference(extension)
	local preferences = config.settings.extension_preferences_table[extension]
	if not preferences or next(preferences) == nil then
		return nil
	end
	local highest_score = 0
	local preferred_extension
	for ext, score in pairs(preferences) do
		if score > highest_score then
			highest_score = score
			preferred_extension = ext
		end
	end
	return preferred_extension, highest_score
end

-- Gives a small bonus if filenames match exactly
function M.get_filename_score(path1, path2)
	local _, filename1 = M.split_filename(path1)
	local _, filename2 = M.split_filename(path2)
	return (filename1 == filename2) and 1 or 0
end

-- Returns the user-configured preference score for an extension
function M.get_extension_score(current_extension, file_extension)
	M.log(string.format("current_extension [%s], file_extension [%s]", current_extension, file_extension))
	local preferences = config.settings.extension_preferences_table[current_extension] or {}
	M.log(string.format("preferences[file_extension] = [%s]", preferences[file_extension]))
	return preferences[file_extension] or 0
end

-- Combines path similarity, extension preference, and filename bonus
function M.calculate_final_score(path1, path2, current_extension, file_extension)
	local path_similarity = M.calculate_similarity(path1, path2)
	local extension_score_weight = 10
	local extension_score = M.get_extension_score(current_extension, file_extension) * extension_score_weight
	local filename_score = M.get_filename_score(path1, path2)
	M.log(
		string.format(
			"Path similarity: %s, Extension score: %d, Filename score: %d",
			path_similarity,
			extension_score,
			filename_score
		)
	)
	return path_similarity + extension_score + filename_score
end

-- Check if a file is already open in any buffer
function M.is_file_open_in_buffer(filepath)
	local abs_path = vim.fn.fnamemodify(filepath, ":p")
	M.log("Checking if file is open: " .. abs_path)

	-- Check all buffers
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local buf_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p")
			M.log("Comparing with buffer: " .. buf_path)

			-- Use direct equality comparison
			if buf_path == abs_path then
				M.log("Match found: " .. abs_path)
				return buf
			end
		end
	end

	M.log("No match found for: " .. abs_path)
	return nil
end

-- Helper function to handle file paths with different directories but same name
function M.find_counterpart_in_current_dir(filepath)
	-- Get the current buffer's directory and the target filename
	local current_buf_path = vim.api.nvim_buf_get_name(0)
	local current_dir = vim.fn.fnamemodify(current_buf_path, ":p:h")
	local target_filename = vim.fn.fnamemodify(filepath, ":t")

	-- Construct the path to check if the file exists in the current directory
	local potential_path = current_dir .. "/" .. target_filename
	M.log("Checking if counterpart exists in current dir: " .. potential_path)

	-- Check if the file exists
	if vim.fn.filereadable(potential_path) == 1 then
		M.log("Found counterpart in current directory: " .. potential_path)
		return potential_path
	end

	-- If not found in current directory, return the original path
	return filepath
end

-- Main entry: prioritizes same directory counterparts, then tries visible switch, then any loaded buffer, then fallback to edit
function M.edit(filepath)
	-- First, prioritize finding the counterpart in the same directory
	local prioritized_path = M.find_counterpart_in_current_dir(filepath)
	local abs_path = vim.fn.fnamemodify(prioritized_path, ":p")
	local caller_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p:h")

	M.log("Original filepath: " .. filepath)
	M.log("Prioritized path: " .. prioritized_path)
	M.log("Absolute path: " .. abs_path)

	-- Step 1: Try to switch to window if visible
	if M.switch_to_open_file_if_possible(abs_path) then
		M.log("Switched to visible window for: " .. abs_path)
		return
	end

	-- Step 2: Check if file is open in any buffer
	local existing_buf = M.is_file_open_in_buffer(abs_path)
	if existing_buf then
		M.log("Switching to existing buffer: " .. vim.api.nvim_buf_get_name(existing_buf))
		vim.api.nvim_set_current_buf(existing_buf)
		return
	end

	-- Step 3: Fallback to opening the file
	M.log("Opening new buffer for: " .. abs_path)
	vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
end

return M
