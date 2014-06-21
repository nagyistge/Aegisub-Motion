karaskel = require "karaskel"
util = require "util"

class LineCollection

	-- This table is used to verify that style defaults are inserted at
	-- the beginning the selected line(s) if the corresponding options are
	-- selected. The structure is: [tag] = { opt:"opt", key:"style key",
	-- skip:val } where "opt" is the option that must be enabled, "style
	-- key" is the key to get the value from the style, and skip specifies
	-- not to write the tag if the style default is that value.
	importantTags: {
		["\\fscx"]: { opt: "scale",    key: "scale_x", skip: 0 }
		["\\fscy"]: { opt: "scale",    key: "scale_y", skip: 0 }
		["\\bord"]: { opt: "border",   key: "outline", skip: 0 }
		["\\shad"]: { opt: "shadow",   key: "shadow",  skip: 0 }
		["\\frz"]:  { opt: "rotation", key: "angle" }
	}

	xPosition: {
		(sx, l, r) -> sx - r
		(sx, l, r) -> l
		(sx, l, r) -> sx/2
	}

	yPosition: {
		(sy, v) -> sy - v
		(sy, v) -> sy/2
		(sy, v) -> v
	}

	new: ( sub, sel ) =>
		@lines = {}
		@collectLines sub, sel

	collectLines: ( sub, sel ) =>
		local dialogueStart
		for x = 1, #sub
			if sub[x].class == "dialogue"
				dialogueStart = x - 1 -- start line of dialogue subs
				break

		@meta, @styles = karaskel.collect_head sub, false
		@endFrame = aegisub.frame_from_ms sub[sel[1]].end_time
		@startFrame = aegisub.frame_from_ms sub[sel[1]].start_time

		preproc_line = karaskel.preproc_line
		frame_from_ms = aegisub.frame_from_ms
		ms_from_frame = aegisub.ms_from_frame

		for i = #sel, 1, -1
			with line = sub[sel[i]]
				.number = sel[i]
				.humanizedNumber = .number - dialogueStart

				preproc_line sub, @meta, @styles, line

				.startFrame = frame_from_ms .start_time
				.endFrame   = frame_from_ms .end_time

				if .startframe < @startframe
					@startframe = .startframe
					@startTime = ms_from_frame .startFrame

				if .endframe > @endframe
					@endframe = .endframe
					@startTime = ms_from_frame .endFrame

				if .endframe - .startframe > 1 and not .comment
					line.transformations = { }
					table.insert @lines, line

		@totalFrames = @endFrame - @startFrame + 1

	-- This function is way longer than it should be, but it performs all
	-- of the necessary operations to get the lines ready for tracking,
	-- which, as it turns out, is quite a lot.
	mungeLinesForFBF: ( config ) =>
		shortFade = "\\fad%(([%d]+),([%d]+)%)"
		longFade  = "\\fade%(([%d]+),([%d]+),([%d]+),([%-%d]+),([%-%d]+),([%-%d]+),([%-%d]+)%)"
		alpha_from_style = util.alpha_from_style
		combineChar = string.char 6
		pow = math.pow

		appendMissingTags = ( block, styleRef ) ->
			for tag, str in pairs @importantTags
				if opts[str.opt] and not block\match tag .. "[%-%d%.]+"
					styleDefault = styleRef[str.key]
					if tonumber( styleDefault ) != str.skip
						block ..= (tag.."%.2f")\format styleDefault
			block

		lexTransforms = ( transform, line ) ->
			transStart, transEnd, transExp, transEffect = transform\match "%(([%-%d]*),?([%-%d]*),?([%d%.]*),?(.+)%)"
			transExp = tonumber( transExp ) or 1
			transStart = tonumber( transStart ) or 0

			transEnd = tonumber( transEnd ) or 0
			if transEnd == 0
				transEnd = line.duration

			table.insert line.transformations, { transStart, transEnd, transExp, transEffect }
			debug "Line %d: \\t(%g,%g,%g,%s) found", transStart, transEnd, transExp, transEffect

		fadToTransform = ( fadStart, fadEnd, alpha, duration ) ->
			local str
			if fadStart > 0
				str = ("\\alpha&HFF&\\t(%d,%s,1,\\alpha%s)")\format 0, fadStart, alpha
			if fadEnd > 0
				str ..= ("\\t(%d,%d,1,\\alpha&HFF&)")\format duration - fadEnd, duration
			str

		for line in *@lines
			with line
				-- The first fad or fade that is found in the line is the one
				-- that is used.
				shortFadeStartPos, shortFadeEndPos = .text\find shortFade
				longFadeStartPos, longFadeEndPos   = .text\find longFade

				-- Make the position a property of the line table, since they'll
				-- be used later to calculate the offset.
				.xPosition, .yPosition = .text\match "\\pos%(([%-%d%.]+),([%-%d%.]+)%)"
				.xOrigin,   .yOrigin   = .text\match "\\org%(([%-%d%.]+),([%-%d%.]+)%)"
				verticalMargin = if .margin_v == 0 then .styleref.margin_v else .margin_v
				leftMargin     = if .margin_l == 0 then .styleref.margin_l else .margin_l
				rightMargin    = if .margin_r == 0 then .styleref.margin_r else .margin_r

				-- I refuse to support \a.
				alignment = .text\match("\\an([1-9])") or .styleref.align

				-- If both \fad and \fade are present, then get rid of all
				-- occurrences of whichever one does not come first.
				if shortFadeStartPos and longFadeStartPos
					if shortFadeStartPos < longFadeStartPos
						.text = .text\gsub longFade, ""
						longFadeStartPos = nil
					else
						.text = .text\gsub shortFade, ""
						shortFadeStartPos = nil

				-- For both \fad and \fade, make sure that there are not repeat
				-- occurrences of the tag and move them to the beginning of the
				-- line. This should theoretically ensure identical behavior
				-- when they are turned into \t.
				local fadStartTime, fadEndTime
				if shortFadeStartPos
					fadStartTime, fadEndTime = .text\sub( shortFadeStartPos+5, shortFadeEndPos-1 )\match( "(\d+),(\d+)" )
					fadStartTime, fadEndTime = tonumber( fadStartTime ), tonumber( fadEndTime )
					.text = "{#{.text\sub shortFadeStartPos, shortFadeEndPos}}#{.text\gsub shortFade, ""}"
				if longFadeStartPos
					.text = "{#{.text\sub longFadeStartPos, longFadeEndPos}}#{.text\gsub longFade, ""}"

				-- Merge all contiguous comment/override blocks. This will make
				-- pretty much everything that follows a lot more sane.
				.text = .text\gsub "}{", combineChar

				-- Perform operations on the first override block of the line.
				.text = .text\gsub "^{(.-)}", ( tagBlock ) ->

					if config.xPosition or config.yPosition and not .xPosition
						.xPosition = @xPosition[alignment%3+1] @meta.res_x, leftMargin, rightMargin
						.yPosition = @yPosition[math.ceil alignment/3] @meta.res_y, verticalMargin
						tagBlock = ("\\pos(%.2f,%.2f)")\format( .xPosition, .yPosition ) .. tagBlock

					if config.origin and not .xOrigin
						.xOrigin = .xPosition
						.yOrigin = .yPosition
						tagBlock = ("\\org(%.2f,%.2f)")\format( .xOrigin, .yOrigin ) .. tagBlock

					if shortFadeStartPos
						replaced = false
						-- Not pedantically correct, as output will not be properly
						-- preserved with lines that set specific alpha values, such
						-- as \1a and so on. Additionally, doesn't handle the case
						-- of multiple alpha tags being placed in the same override
						-- block, and so can spawn more transforms than necessary.
						tagBlock = tagBlock\gsub "\\alpha(&H%x%x&)", ( alpha ) ->
							replaced = true
							fadToTransform fadStartTime, fadEndTime, alpha, .duration
						unless replaced
							-- Has the same problem mentioned above.
							tagBlock ..= fadToTransform fadStartTime, fadEndTime, alpha_from_style( .styleref.color1 ), .duration
					elseif longFadeStartPos
						-- This is also completely wrong, as existing alpha tags
						-- aren't even taken into account. However, in this case,
						-- properly handling the fade is much more complex, as alpha
						-- tags influence both the starting and ending transparency
						-- of the fade in an additive fashion. Given that very few
						-- (if any) people use \fade, I don't think the effort
						-- necessary to fix this behavior is worth it at the moment.
						tagBlock = tagBlock\gsub "\\fade%(([%d]+),([%d]+),([%d]+),([%-%d]+),([%-%d]+),([%-%d]+),([%-%d]+)%)",
							(a, b, c, d, e, f, g) ->
								("\\alpha&H%02X&\\t(%s,%s,1,\\alpha&H%02X&)\\t(%s,%s,1,\\alpha&H%02X&)")\format(a, d, e, b, f, g, c)

					tagBlock\gsub "\\t(%b())", ( tContents ) ->
						lexTransforms tContents, line

					-- There is no check for \r in the first tag block in this
					-- code, so in theory, it will do the wrong thing in certain
					-- scenarios. However, if you are putting \r[style] at the
					-- beginning of your line you are an idiot.
					tagBlock = appendMissingTags tagBlock, .styleref

					-- Purposefully leave the opening tag off so that the first
					-- block will not get picked up in the following block
					-- manipulations.
					tagBlock .. '}'

				.text = .text\gsub "{(.-)}", ( tagBlock ) ->
					if shortFadeStartPos
						tagBlock = tagBlock\gsub "\\alpha(&H%x%x&)", ( alpha ) ->
							fadToTransform fadStartTime, fadEndTime, alpha, .duration

					tagBlock\gsub "\\t(%b())", ( tContents ) ->
						lexTransforms tContents, line

					-- The scope abuse inside of this gsub is pretty awkward.
					tagBlock\gsub "\\r([^\\}#{combineChar}]*)", ( resetStyle ) ->
						styleRef = @styles[rstyle] or .styleref
						tagBlock = appendMissingTags( tagBlock, styleRef )

				-- It is possible to have both a rectangular and vector clip in
				-- the same line. This is useful for masking lines with
				-- gradients. In order to be able to support this (even though
				-- motion tracking gradients is a bad idea and not endorsed by
				-- this author), we need to both support multiple clips in one
				-- line, as well as not convert rectangular-style clips to
				-- vector clips. To make our lives easier, we'll just not
				-- enforce any limits on the number of clips in a line and
				-- assume the user knows what they're doing.
				.text = .text\gsub "\\(i?clip)(%b())", ( clip, points ) ->
					.hasClip = true
					if points\match "[%-%d%.]+,[%-%d%.]+,[%-%d%.]+"
						.hasRectangularClip = true
					else
						.hasVectorClip = true
						points = points\gsub "%(([%d]*),?(.-)%)", ( scaleFactor, points ) ->
							if scaleFactor ~= ""
								scaleFactor = tonumber scaleFactor
								-- Other number separators such as ',' are valid in
								-- vector clips, but standard tools don't create them.
								-- Ignore that parser flexibility to make our lives less
								-- difficult. Convert everything to floating point
								-- values for simplicity's sake.
								points = points\gsub "([%.%d%-]+) ([%.%d%-]+)", ( x, y ) ->
									x = tonumber( x )/2^(scaleFactor - 1)
									y = tonumber( y )/2^(scaleFactor - 1)
									-- Round the calculated values so that they don't take
									-- up huge amounts of space.
									("%.2f %.2f")\format x, y
							points
					"\\#{clip}(#{points})"
