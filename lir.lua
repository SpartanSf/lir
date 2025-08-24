local json = require("json")

local function read_ir(filename)
    local f = io.open(filename, "r")
    if not f then error("cannot open "..filename) end
    local data = json.decode(f:read("*a"))
    f:close()
    return data
end

local irData = read_ir("example.lir")


local locals = {}
if irData.locals and #irData.locals > 0 then
    for i, name in ipairs(irData.locals) do locals[#locals+1] = name end
else
    local seen = {}
    local add = function(name)
        if type(name) == "string" and not seen[name] then
            seen[name] = true
            locals[#locals+1] = name
        end
    end
    for _, block in ipairs(irData.blocks or {}) do
        for _, instr in ipairs(block.instrs or {}) do
            if instr.dst then add(instr.dst) end
            if instr.src then add(instr.src) end
            if instr.idx then add(instr.idx) end
            if instr.func then add(instr.func) end
            if instr.args then
                for _, a in ipairs(instr.args) do if type(a) == "string" then add(a) end end
            end
        end
    end
end

local locals_map = {}
for i, name in ipairs(locals) do
    locals_map[name] = i-1
end

local function getReg(op)
    if type(op) == "table" then
        if op.kind == "const" then return "K" .. tostring(op.idx) end
        if op.kind == "up" then return "U" .. tostring(op.idx) end
        if op.kind == "reg" then return (op.raw or ("R" .. tostring(op.idx))) end
        error("unknown operand table kind: "..tostring(op.kind))
    end

    if type(op) ~= "string" then return tostring(op) end

    if op:match("^R%d+$") then return op end
    if op:match("^K%d+$") or op:match("^U%d+$") then return op end

    if locals_map[op] ~= nil then
        return "R" .. tostring(locals_map[op])
    end

    if op:sub(1,1) == "$" then
        local name = op:sub(2)
        if locals_map[name] == nil then
            locals_map[name] = #locals_map
            return "R" .. tostring(locals_map[name])
        else
            return "R" .. tostring(locals_map[name])
        end
    end

    locals_map[op] = locals_map[op] or (#locals_map)
    return "R" .. tostring(locals_map[op])
end

local function build_header_line(header)
    local order = { "numparams", "is_vararg", "maxstack" }
    local parts = {}
    for _, k in ipairs(order) do
        if header[k] ~= nil then
            table.insert(parts, k .. "=" .. tostring(header[k]))
        end
    end

    for k, v in pairs(header) do
        local found = false
        for _, kk in ipairs(order) do if kk == k then found = true end end
        if not found then table.insert(parts, k .. "=" .. tostring(v)) end
    end
    return table.concat(parts, ", ")
end

local function escape_string(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub("\"", "\\\"")
    return s
end

local function parseBlock(block)
    local lines = {}
    local function new(l) table.insert(lines, l) end

    new(block.name .. ":")
    new(".scope")

    for _, instr in ipairs(block.instrs or {}) do -- TODO: make this a dispatch table
        if instr.op == "const" then
            new("LOADK " .. getReg(instr.dst) .. " K" .. tostring(instr.c))
        elseif instr.op == "for_prep" then
            new("FORPREP " .. getReg(instr.idx) .. " " .. instr.loop)
        elseif instr.op == "for_loop" or instr.op == "forloop" then
            new("FORLOOP " .. getReg(instr.idx) .. " " .. instr.body)
        elseif instr.op == "getfield_env" then
            new("GETTABUP " .. getReg(instr.dst) .. " U0 K" .. tostring(instr.key_c))
        elseif instr.op == "move" then
            new("MOVE " .. getReg(instr.dst) .. " " .. getReg(instr.src))

        elseif instr.op == "call" then
            local nargs = #instr.args
            local nrets = instr.nret or 0
            new("CALL " .. getReg(instr.func) .. " " .. tostring(nargs + 1) .. " " .. tostring(nrets))
        elseif instr.op == "ret" or instr.op == "return" then
            local args = {}
            for _, a in ipairs(instr.args or {}) do
                table.insert(args, getReg(a))
            end
            if #args == 0 then
                new("RETURN 0 0")
            elseif #args == 1 then
                new("RETURN " .. args[1] .. " " .. tostring(#args))
            else
                new("RETURN " .. table.concat(args, " ") .. " " .. tostring(#args))
            end
        else
            if instr.raw then
                new(instr.raw)
            else
                error("unknown op: " .. tostring(instr.op))
            end
        end
    end

    new(".endscope")
    return table.concat(lines, "\n")
end

local out = {}

table.insert(out, ".fn @" .. (irData["function"] or "anonymous"))
table.insert(out, ".header")
table.insert(out, build_header_line(irData.header or {}) )
table.insert(out, "") -- newline

table.insert(out, ".instruction")

for _, block in ipairs(irData.blocks or {}) do
    table.insert(out, parseBlock(block))
    table.insert(out, "")
end

table.insert(out, ".const")
for i, v in ipairs(irData.consts or {}) do
    if type(v) == "number" then
        table.insert(out, "K" .. (i-1) .. " = " .. tostring(v))
    else
        table.insert(out, "K" .. (i-1) .. " = \"" .. escape_string(tostring(v)) .. "\"")
    end
end

if irData.upvalues and #irData.upvalues > 0 then
    table.insert(out, ".upvalue")
    for i, uv in ipairs(irData.upvalues) do
        if type(uv) == "string" then
            table.insert(out, "U" .. (i-1) .. " = " .. uv)
        else
            local name = uv.name or ("U" .. (i-1))
            local info = uv.info or (uv.ref or "")
            table.insert(out, name .. " = " .. info)
        end
    end
else
    table.insert(out, ".upvalue")
    table.insert(out, "U0 = L0 R0")
end

table.insert(out, ".endfn")

local asmFile = io.open("result.lbasm", "w")
asmFile:write(table.concat(out, "\n"))
asmFile:close()

print("wrote result.lbasm")
