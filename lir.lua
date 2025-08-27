local json = require("json")
local serpent = require("serpent")

local function read_ir(filename)
    local f = io.open(filename, "r")
    if not f then error("cannot open "..filename) end
    local data = json.decode(f:read("*a"))
    f:close()
    return data
end

local irData = read_ir("tests/t4.lir")

local function is_normalized(ir)
    if not ir or not ir.blocks or #ir.blocks == 0 then return false end
    for _, b in ipairs(ir.blocks) do
        for _, instr in ipairs(b.instrs or {}) do
            if instr.operands ~= nil then
                return true
            end
        end
    end
    return false
end

if not is_normalized(irData) then
    error("lir.lua expects normalized IR (instr.operands present). Please run the converter first.")
end

local function is_reg_operand(o) return type(o) == "table" and o.kind == "reg" end

local locals = {}
local seen = {}
local function add_local_name(n)
    if type(n) == "string" and not seen[n] then
        seen[n] = true
        locals[#locals+1] = n
    end
end

for _, block in ipairs(irData.blocks or {}) do
    for _, instr in ipairs(block.instrs or {}) do
        if instr.dst and type(instr.dst) == "string" then add_local_name(instr.dst) end
        for _, op in ipairs(instr.operands or {}) do
            if is_reg_operand(op) then add_local_name(op.name) end
        end
    end
end

local locals_map = {}


local loop_base_by_stem = {}

local function name_stem(name)
    if type(name) ~= "string" then return tostring(name) end
    return name:gsub("%.%d+$", "")
end

local function next_free_index(min_index)
    min_index = min_index or 0
    local used = {}
    for _, v in pairs(locals_map) do used[v] = true end
    local i = min_index
    while used[i] do i = i + 1 end
    return i
end

local function reserve_range(start_index, len)
    len = len or 1
    for idx = start_index, start_index + len - 1 do
        local occupied = false
        for name, v in pairs(locals_map) do
            if v == idx then occupied = true; break end
        end
        if not occupied then
            local ph = "__reserved_R" .. tostring(idx)
            if locals_map[ph] == nil then
                locals_map[ph] = idx
                locals[#locals+1] = ph
            end
        end
    end
end

local function force_reg_index(name, want_index)
    if type(name) ~= "string" then return end
    if locals_map[name] == want_index then return end
    locals_map[name] = want_index
    local seen = false
    for _, n in ipairs(locals) do if n == name then seen = true break end end
    if not seen then table.insert(locals, name) end
end

local function getReg(op)
    if type(op) == "table" then
        if op.kind == "const" then return "K" .. tostring(op.idx) end
        if op.kind == "up" then return "U" .. tostring(op.idx) end
        if op.kind == "reg" then
            local n = op.name
            local stem = name_stem(n)
            local base = loop_base_by_stem[stem]
            if locals_map[n] == nil and base ~= nil then
                locals_map[n] = base + 3
                locals[#locals+1] = n
                return "R" .. tostring(locals_map[n])
            end

            if locals_map[n] == nil then
                local idx = next_free_index(0)
                locals_map[n] = idx
                locals[#locals+1] = n
            end
            return "R" .. tostring(locals_map[n])
        end
        error("unknown operand table kind: "..tostring(op.kind))
    end

    if type(op) ~= "string" then return tostring(op) end
    if op:match("^R%d+$") then return op end
    if op:match("^K%d+$") or op:match("^U%d+$") then return op end

    if locals_map[op] ~= nil then
        return "R" .. tostring(locals_map[op])
    end

    local stem = name_stem(op)
    local base = loop_base_by_stem[stem]
    if base ~= nil then
        locals_map[op] = base + 3
        locals[#locals+1] = op
        return "R" .. tostring(locals_map[op])
    end

    local idx = next_free_index(0)
    locals_map[op] = idx
    locals[#locals+1] = op
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

    for _, instr in ipairs(block.instrs or {}) do
        local op = (instr.op or ""):lower()

        if op == "const" then
            local k = instr.operands and instr.operands[1]
            local kidx = k and k.idx or (instr.meta and instr.meta.k)
            new("LOADK " .. getReg(instr.dst) .. " K" .. tostring(kidx))

        elseif op == "forprep" then
            local ops = instr.operands or {}
            local idxop, limop, stepop = ops[1], ops[2], ops[3]
            local target = (instr.meta and (instr.meta.target or instr.meta.loop or instr.meta.body)) or error("forprep target missing")

            local idx_name = (type(idxop)=="table" and idxop.kind=="reg") and idxop.name or tostring(idxop)
            local base = locals_map[idx_name]
            if base == nil then base = next_free_index(0) end

            print("; DEBUG: FORPREP stem=" .. tostring(name_stem(idx_name)) .. " base=R" .. tostring(base))

            reserve_range(base, 4)

            force_reg_index(idx_name, base)
            if type(limop)=="table" and limop.kind=="reg" then force_reg_index(limop.name, base+1) end
            if type(stepop)=="table" and stepop.kind=="reg" then force_reg_index(stepop.name, base+2) end

            loop_base_by_stem[name_stem(idx_name)] = base

            local stem = name_stem(idx_name)

            for nm, _ in pairs(locals_map) do
                if type(nm) == "string" and nm ~= idx_name and name_stem(nm) == stem then
                    force_reg_index(nm, base + 3)
                end
            end

            loop_base_by_stem[stem] = base

            local function emit_to_R(Ri, operand)
                if type(operand) == "table" then
                    if operand.kind == "const" then
                        table.insert(lines, "LOADK R"..Ri.." K"..tostring(operand.idx))
                    elseif operand.kind == "reg" then
                        local src = getReg(operand)
                        if src ~= ("R"..Ri) then table.insert(lines, "MOVE R"..Ri.." "..src) end
                    else
                        error("FORPREP expects reg/const for idx/limit/step")
                    end
                else
                    local src = getReg({ kind="reg", name=operand })
                    if src ~= ("R"..Ri) then table.insert(lines, "MOVE R"..Ri.." "..src) end
                end
            end

            if idxop  then emit_to_R(base+0, idxop)  end
            if limop  then emit_to_R(base+1, limop)  end
            if stepop then emit_to_R(base+2, stepop) end

            table.insert(lines, "FORPREP R"..tostring(base).." "..tostring(target))

        elseif op == "forloop" then
            local idxop = instr.operands and instr.operands[1]
            local body  = (instr.meta and instr.meta.body) or error("forloop body label missing")

            local base_reg = nil
            if type(idxop) == "table" and idxop.kind == "reg" then
                base_reg = loop_base_by_stem[name_stem(idxop.name)]
            end

            if base_reg ~= nil then
                new("FORLOOP R" .. tostring(base_reg) .. " " .. tostring(body))
            else
                new("FORLOOP " .. getReg(idxop) .. " " .. tostring(body))
            end

        elseif op == "getfield_env" or op == "gettabup" then
            local up = instr.operands and instr.operands[1]
            local k  = instr.operands and instr.operands[2]
            new("GETTABUP " .. getReg(instr.dst) .. " " .. getReg(up) .. " K" .. tostring((k and k.idx) or 0))

        elseif op == "move" then
            local srcop = instr.operands and instr.operands[1]
            new("MOVE " .. getReg(instr.dst) .. " " .. getReg(srcop))

        elseif op == "call" then
            local ops = instr.operands or {}
            local funcop = ops[1]
            local nargs = math.max(0, #ops - 1)
            local nrets = (instr.meta and instr.meta.nret) or 1

            local function reg_of(name) return getReg({ kind="reg", name=name }) end
            print("; DEBUG-REGS: %f.1=" .. reg_of("%f.1")
            .. " %idx.2=" .. reg_of("%idx.2")
            .. " %arg.1=" .. reg_of("%arg.1"))

            new("CALL " .. getReg(funcop) .. " " .. tostring(nargs + 1) .. " " .. tostring(nrets))

        elseif op == "ret" or op == "return" then
            local regs = {}
            for i, a in ipairs(instr.operands or {}) do
                local Rname = getReg(a)
                if Rname:match("^K%d+$") then
                    local tmp = next_free_index(0)
                    locals_map["__ret_tmp"..i] = tmp
                    locals[#locals+1] = "__ret_tmp"..i
                    table.insert(lines, "LOADK R"..tmp.." "..Rname)
                    Rname = "R"..tmp
                end
                table.insert(regs, Rname)
            end

            if #regs == 0 then
                new("RETURN 0 0")
            elseif #regs == 1 then
                new("RETURN "..regs[1].." 2")
            else
                new("RETURN "..table.concat(regs, " ").." "..tostring(#regs+1))
            end

        elseif op == "add" or op == "sub" or op == "mul" or op == "div" or op == "mod" then
            local ops = instr.operands or {}
            local dst = getReg(instr.dst)
            local a   = getReg(ops[1])
            local b   = getReg(ops[2])
            new(string.upper(op) .. " " .. dst .. " " .. a .. " " .. b)

        elseif op == "newtable" then
            local arr = (instr.meta and instr.meta.array) or 0
            local hash = (instr.meta and instr.meta.hash) or 0
            new("NEWTABLE " .. getReg(instr.dst) .. " " .. tostring(arr) .. " " .. tostring(hash))

        elseif op == "settable" then
            local ops = instr.operands or {}
            local keyop = ops[1]
            local valop = ops[2]

            if not keyop or not valop then
                error("SETTABLE expects two operands (key, value)")
            end

            local tableReg = getReg(instr.dst)
            local keyTok   = (type(keyop) == "table") and getReg(keyop) or getReg({ kind="reg", name=tostring(keyop) })
            local valTok   = (type(valop) == "table") and getReg(valop) or getReg({ kind="reg", name=tostring(valop) })

            new("SETTABLE " .. tableReg .. " " .. keyTok .. " " .. valTok)

        elseif op == "settabup" then
            local ops = instr.operands or {}
            local up = ops[1]; local keyop = ops[2]; local valop = ops[3]
            if not up or not keyop or not valop then
                error("SETTABUP expects (up, key, value)")
            end
            new("SETTABUP " .. getReg(instr.dst) .. " " .. getReg(up) .. " " .. getReg(keyop) .. " " .. getReg(valop))

        else
            if instr.meta and instr.meta.raw then
                new(instr.meta.raw)
            else
                error("unknown op in emitter: " .. tostring(instr.op))
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
table.insert(out, "")

table.insert(out, ".instruction")

for _, block in ipairs(irData.blocks or {}) do
    table.insert(out, parseBlock(block))
    table.insert(out, "")
end

table.insert(out, ".const")

local seen_consts = {}
for i, v in ipairs(irData.consts or {}) do
    local kname = "K" .. (i-1)
    local key

    if type(v) == "table" then
        key = serpent.serialize(v, {compact=true})
        table.insert(out, kname .. " = " .. key)
    elseif type(v) == "number" then
        key = tostring(v)
        table.insert(out, kname .. " = " .. key)
    else
        key = tostring(v)
        table.insert(out, kname .. " = \"" .. escape_string(key) .. "\"")
    end

    if seen_consts[key] then
    else
        seen_consts[key] = true
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

for name, idx in pairs(locals_map) do
    print("; LOCAL " .. tostring(name) .. " -> R" .. tostring(idx))
end
for stem, base in pairs(loop_base_by_stem) do
    print("; LOOPBASE " .. tostring(stem) .. " -> R" .. tostring(base))
end


local asmFile = io.open("result.lbasm", "w")
asmFile:write(table.concat(out, "\n"))
asmFile:close()

print("wrote result.lbasm")
