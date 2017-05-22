--[[
模块名称：程序运行框架
模块功能：初始化，程序运行框架、消息分发处理、定时器接口
模块最后修改时间：2017.02.17
]]

--定义模块,导入依赖库
require"patch"

local base = _G
local table = require"table"
local rtos = require"rtos"
local uart = require"uart"
local io = require"io"
local os = require"os"
local pio = require"pio"
local watchdog = require"watchdog"
local bit = require"bit"
local string = require"string"
module("sys")

--加载常用的全局函数至本地
local print = base.print
local unpack = base.unpack
local ipairs = base.ipairs
local type = base.type
local pairs = base.pairs
local assert = base.assert
local tonumber = base.tonumber
local isn = 65535
local hasPwrKey = false
local opntrc = {}

--lib脚本版本号，只要lib中的任何一个脚本做了修改，都需要更新此版本号
SCRIPT_LIB_VER = "1.0.3"
--支持lib脚本的最小core软件版本号
CORE_MIN_VER = "Luat_V0005_Air810"

--“是否需要刷新界面”的标志，有GUI的项目才会用到此标志
local refreshflag = false
--[[
函数名：refresh
功能  ：设置界面刷新标志，有GUI的项目才会用到此接口
参数  ：无
返回值：无
]]
function refresh()
	refreshflag = true
end

--定时器支持的单步最大时长，单位毫秒
local MAXMS = 0x7fffffff/17
--定时器id
local uniquetid = 0
--定时器id表
local tpool = {}
--定时器参数表
local para = {}
--定时器是否循环表
local loop = {}
--lprfun：用户自定义的“低电关机处理程序”
--lpring：是否已经启动自动关机定时器
local lprfun,lpring
--错误信息文件以及错误信息内容
local LIB_ERR_FILE,liberr = "/lib_err.txt",""
--工作模式
--SIMPLE_MODE：简单模式，默认不会开启“每一分钟产生一个内部消息”、“定时查询csq”、“定时查询ceng”的功能
--FULL_MODE：完整模式，默认会开启“每一分钟产生一个内部消息”、“定时查询csq”、“定时查询ceng”的功能
SIMPLE_MODE,FULL_MODE = 0,1
--默认为完整模式
local workmode = FULL_MODE

--[[
函数名：timerfnc
功能  ：处理底层core上报的外部定时器消息
参数  ：
		utid：定时器id
返回值：无
]]
local function timerfnc(utid)
  local tid,sn= bit.band(utid, 0xffff),bit.band((bit.rshift(utid,16)), 0xffff)

	if tpool[tid] ~= nil then
		--此定时器的回调函数
		local cb = tpool[tid].cb
		
		if tpool[tid].sn ~= sn or not cb then
		  print("invalid timerfnc tid:",tid,"sn:",sn,"realsn:",tpool[tid].sn)
		  return
		end

		local tval = tpool[tid]
		if tval.times and tval.total and tval.step then
			tval.times = tval.times+1
			--拆分的几个定时器还未执行完毕，继续执行下一个
			if tval.times < tval.total then
				rtos.timer_start(tid,tval.step)
				return
			end
		end
		--如果不是循环定时器，从定时器id表中清除此定时器id位置的内容
		if not loop[tid] then tpool[tid] = nil end
		--存在自定义可变参数
		if para[tid] ~= nil then
			local pval = para[tid]
			--如果不是循环定时器，从定时器参数表中清除此定时器id位置的内容
			if not loop[tid] then para[tid] = nil end
			--执行定时器回调函数
			cb(unpack(pval))
		--不存在自定义可变参数
		else
			--执行定时器回调函数
			cb()
		end

		--如果是循环定时器，继续启动此定时器
		if loop[tid] then 
		  isn = isn==65535 and 0 or isn+1
		  tpool[tid].sn = isn
		  local lptid = bit.bor(bit.lshift(isn,16),tid)
		  rtos.timer_start(lptid,loop[tid]) 
		end
	end
end

--[[
函数名：comp_table
功能  ：比较两个table的内容是否相同，注意：table中不能再包含table
参数  ：
		t1：第一个table
		t2：第二个table
返回值：相同返回true，否则false
]]
local function comp_table(t1,t2)
	if not t2 then
	  if not t1 then return #t1 == 0 end
	  return true
	end
	if #t1 == #t2 then
		for i=1,#t1 do
			if unpack(t1,i,i) ~= unpack(t2,i,i) then
				return false
			end
		end
		return true
	end
	return false
end

--[[
函数名：timer_start
功能  ：开启一个定时器
参数  ：
		fnc：定时器的回调函数
		ms：定时器时长，单位为毫秒
		...：自定义可变参数
		注意：fnc和可变参数...共同标记唯一的一个定时器
返回值：定时器的ID，如果失败返回nil
]]
function timer_start(fnc,ms,...)
	--回调函数必须有效，否则死机重启
	assert(fnc ~= nil,"timer_start:callback function == nil")
	if ms==nil then
        print("sys.timer_start",fnc)
        return
	end
	if arg.n == 0 then
		timer_stop(fnc)
	else
		timer_stop(fnc,unpack(arg))
	end
	isn = isn==65535 and 0 or isn+1
	
	--如果时长超过单步支持的最大时长，则拆分为几个定时器
	if ms > MAXMS then
		local count = ms/MAXMS + (ms%MAXMS == 0 and 0 or 1)
		local step = ms/count
		tval = {cb = fnc, step = step, total = count, times = 0,sn = isn}
		ms = step
	--时长未超过单步支持的最大时长
	else
		tval = {cb = fnc,sn = isn}
	end
	uniquetid = 1

	--从定时器id表中找到一个未使用的id使用
	while true do
		if tpool[uniquetid] == nil then
			tpool[uniquetid] = tval
			break
		end
		uniquetid = uniquetid + 1
	end
	local tid = bit.bor(bit.lshift(isn,16),uniquetid)
	--调用底层接口启动定时器
	if rtos.timer_start(tid,ms) ~= 1 then print("rtos.timer_start error") return end
	--如果存在可变参数，在定时器参数表中保存参数
	if arg.n ~= 0 then
		para[uniquetid] = arg
	end
	--返回定时器id,队列id,sn
	return tid,uniquetid,tpool[uniquetid].sn
end

--[[
函数名：timer_loop_start
功能  ：开启一个循环定时器
参数  ：
		fnc：定时器的回调函数
		ms：定时器时长，单位为毫秒
		...：自定义可变参数
		注意：fnc和可变参数...共同标记唯一的一个定时器
返回值：定时器的ID，如果失败返回nil
]]
function timer_loop_start(fnc,ms,...)
	local tid,utid,sn = timer_start(fnc,ms,unpack(arg))
	if utid then loop[utid] = ms end
	return tid
end

--[[
函数名：timer_stop
功能  ：关闭一个定时器
参数  ：
		val：有两种形式：
		     一种是开启定时器时返回的定时器id，此形式时不需要再传入可变参数...就能唯一标记一个定时器
			 另一种是开启定时器时的回调函数，此形式时必须再传入可变参数...才能唯一标记一个定时器
		...：自定义可变参数，与timer_start和timer_loop_start中的可变参数意义相同
返回值：无
]]
function timer_stop(val,...)
	--val为定时器id
	if type(val) == "number" then
		tpool[val],para[val],loop[val] = nil
	else
		for k,v in pairs(tpool) do
			--回调函数相同
			if type(v) == "table" and v.cb == val then
				--自定义可变参数相同
				if comp_table(arg,para[k])then
					rtos.timer_stop(k)
					tpool[k],para[k],loop[k] = nil
					break
				end
			end
		end
	end
end

--[[
函数名：timer_stop_all
功能  ：关闭某个回调函数标记的所有定时器，无论开启定时器时有没有传入自定义可变参数
参数  ：
		fnc：开启定时器时的回调函数
返回值：无
]]
function timer_stop_all(fnc)
	for k,v in pairs(tpool) do
		if type(v) == "table" and v.cb == fnc then
			rtos.timer_stop(k)
			tpool[k],para[k],loop[k] = nil
		end
	end
end

--[[
函数名：timer_is_active
功能  ：判断某个定时器是否处于开启状态
参数  ：
		val：有两种形式：
		     一种是开启定时器时返回的定时器id，此形式时不需要再传入可变参数...就能唯一标记一个定时器
			 另一种是开启定时器时的回调函数，此形式时必须再传入可变参数...才能唯一标记一个定时器
		...：自定义可变参数，与timer_start和timer_loop_start中的可变参数意义相同
返回值：开启返回true，否则false
]]
function timer_is_active(val,...)
	if type(val) == "number" then
		return tpool[val] ~= nil
	else
		for k,v in pairs(tpool) do
			if type(v) == "table" and v.cb == val or v == val then
				if comp_table(arg,para[k]) then
					return true
				end
			end
		end
		return false
	end
end

function timer_is_active_anyone(val,...)
	if type(val) == "number" then
		return tpool[val] ~= nil
	else
		for k,v in pairs(tpool) do
			if type(v) == "table" and v.cb == val or v == val then
				--if comp_table(arg,para[k]) then
					return true
				--end
			end
		end
		return false
	end
end

--[[
函数名：readtxt
功能  ：读取文本文件中的全部内容
参数  ：
		f：文件路径
返回值：文本文件中的全部内容，读取失败为空字符串或者nil
]]
local function readtxt(f)
	local file,rt = io.open(f,"r")
	if not file then print("sys.readtxt no open",f) return "" end
	rt = file:read("*a")
	file:close()
	return rt
end

--[[
函数名：writetxt
功能  ：写文本文件
参数  ：
		f：文件路径
		v：要写入的文本内容
返回值：无
]]
local function writetxt(f,v)
	local file = io.open(f,"w")
	if not file then print("sys.writetxt no open",f) return end	
	local rt = file:write(v)
	if not rt then
		removegpsdat()
		file:write(v)		
	end
	file:close()
end

--[[
函数名：appenderr
功能  ：追加错误信息到LIB_ERR_FILE文件中
参数  ：
		s：错误信息，用户自定义，一般是string类型，重启后的trace中会打印出此错误信息
返回值：无
]]
local function appenderr(s)
	liberr = liberr..s
	writetxt(LIB_ERR_FILE,liberr)	
end

--[[
函数名：initerr
功能  ：打印LIB_ERR_FILE文件中的错误信息
参数  ：无
返回值：无
]]
local function initerr()
	liberr = readtxt(LIB_ERR_FILE) or ""
	print("sys.initerr",liberr)
	--删除LIB_ERR_FILE文件
	os.remove(LIB_ERR_FILE)
end

local poweroffcb
function regpoweroffcb(cb)
	poweroffcb = cb
end

--[[
函数名：restart
功能  ：软件重启
参数  ：
		r：重启原因，用户自定义，一般是string类型，重启后的trace中会打印出此重启原因
返回值：无
]]
function restart(r)
	base.print("sys restart:",r)
	assert(r and r ~= "","sys.restart cause null")
	appenderr("restart["..r.."];")
	if poweroffcb then poweroffcb() end
	rtos.restart()	
end

--[[
函数名：getcorever
功能  ：获取底层软件版本号
参数  ：无
返回值：版本号字符串
]]
function getcorever()
	return rtos.get_version()
end

--[[
函数名：checkcorever
功能  ：检查底层软件版本号和lib脚本需要的最小底层软件版本号是否匹配
参数  ：无
返回值：无
]]
local function checkcorever()
  local regularexp = "[lL][uU][aA][tT]_[vV](%d+)_[aA][iI][rR](%w+)"
  local realver = getcorever()
	--如果没有获取到底层软件版本号
	if not realver or realver=="" then
		appenderr("checkcorever[no core ver error];")
		return
	end
	
	local buildver = string.match(realver,regularexp)

	--如果底层软件版本号格式错误
	if not buildver then
		appenderr("checkcorever[core ver format error]"..realver..";")
		return
	end
	
	--lib脚本需要的底层软件版本号大于底层软件的实际版本号
	local minver = string.match(CORE_MIN_VER,regularexp)
	if tonumber(minver) > tonumber(buildver) then
		appenderr("checkcorever[core ver match error]"..realver..","..CORE_MIN_VER..";")
	end
end

--[[
函数名：repwron
功能  ：充电器再开机接口
参数  ：无
返回值：无
]]
function repwron()
  return rtos.repoweron()
end

--[[
函数名：poweroff
功能  ：关机接口
参数  ：
    r：关机原因
返回值：无
]]
function poweroff(r)
	base.print("sys poweroff:",r)
	if r then appenderr("poweroff["..r.."];") end
	if poweroffcb then poweroffcb() end
	rtos.poweroff()
end

--[[
函数名：isPwronCharger
功能  ：判断是否为充电器开机
参数  ：无
返回值：true,充电器开机；false,非充电器开机。
]]
function isPwronCharger()
  if rtos.poweron_reason() == rtos.POWERON_CHARGER then
    return true
  end
  
  return false
end

--[[
函数名：setPwronCharger
功能  ：设置开机标识
参数  ：
  has 标识
返回值：无
]]
function setPwrFlag(has)
  hasPwrKey = has
end

--[[
函数名：getPwrFlag
功能  ：获得开机标识
参数  ：无
返回值：true,按键开机；false,非按键开机。
]]
function getPwrFlag()
  return hasPwrKey
end

--[[
函数名：init
功能  ：lua应用程序初始化
参数  ：
		mode：充电开机是否启动GSM协议栈，1不启动，否则启动
		lprfnc：用户应用脚本中定义的“低电关机处理函数”，如果有函数名，则低电时，本文件中的run接口不会执行任何动作，否则，会延时1分钟自动关机
返回值：无
]]
function init(mode,lprfnc)
	--用户应用脚本中必须定义PROJECT和VERSION两个全局变量，否则会死机重启，如何定义请参考各个demo中的main.lua
	assert(base.PROJECT and base.PROJECT ~= "" and base.VERSION and base.VERSION ~= "","Undefine PROJECT or VERSION")
	base.require"keypad"
	--设置AT命令的虚拟串口
	uart.setup(uart.ATC,0,0,uart.PAR_NONE,uart.STOP_1)
	print("init mode :",mode,lprfnc)
	print("poweron reason:",rtos.poweron_reason(),mode,base.PROJECT,base.VERSION)

	-- 模式0 充电器和闹钟开机都不注册网络
  if mode == 0 then
    if rtos.poweron_reason() ~= rtos.POWERON_CHARGER then
      setPwrFlag(true)
    else
      setPwrFlag(false)
    end
  end
	
	-- 模式1 充电器和闹钟开机都注册网络
	if mode == 1 then
		if rtos.poweron_reason() == rtos.POWERON_CHARGER 
			or rtos.poweron_reason() == rtos.POWERON_ALARM  then
			rtos.repoweron()
		end
	--模式2 充电器开机注册网络，闹钟开机不注册网络
	elseif  mode == 2 then
		if rtos.poweron_reason() == rtos.POWERON_CHARGER then
			rtos.repoweron()
		end
	--模式2 闹钟开机注册网络，充电器开机不注册网络
	elseif  mode == 3 then
		if rtos.poweron_reason() == rtos.POWERON_ALARM  then
			rtos.repoweron()
		end
	end
	
	--发送MSG_POWERON_REASON消息
	base.require"net"
	dispatch("MSG_POWERON_REASON",rtos.poweron_reason())
	--如果存在脚本运行错误文件，打开文件，打印错误信息
	local f = io.open("/luaerrinfo.txt","r")
	if f then
		print(f:read("*a") or "")
		f:close()
	end
	--保存用户应用脚本中定义的“低电关机处理函数”
	lprfun = lprfnc
	initerr()
	checkcorever()
end

--[[
函数名：poweron
功能  ：启动GSM协议栈。例如在充电开机未启动GSM协议栈状态下，如果用户长按键正常开机，此时调用此接口启动GSM协议栈即可
参数  ：无
返回值：无
]]
function poweron()
	rtos.poweron(1)
end

--[[
函数名：setworkmode
功能  ：设置工作模式
参数  ：
		v：工作模式
返回值：成功返回true，否则返回nil
]]
function setworkmode(v)
	if workmode~=v and (v==SIMPLE_MODE or v==FULL_MODE) then
		workmode = v
		--产生一个工作模式变化的内部消息"SYS_WORKMODE_IND"
		dispatch("SYS_WORKMODE_IND")
		return true
	end
end

--[[
函数名：getworkmode
功能  ：获取工作模式
参数  ：无
返回值：当前工作模式
]]
function getworkmode()
	return workmode
end

--[[
函数名：opntrace
功能  ：开启或者关闭print的打印输出功能
参数  ：
    v：false或nil为关闭，其余为开启
    uartid：输出Luatrace的端口：nil表示host口，1表示uart1,3表示uart3
    baudrate：number类型，uartid不为nil时，此参数才有意义，表示波特率，默认115200
          仅支持1200,2400,4800,9600,14400,19200,28800,38400,57600,76800,115200,230400,460800,576000,921600,1152000,4000000
返回值：无
]]
local function opnsettrace(v,uartid,baudrate)
  if uartid then
    if v then
      uart.setup(uartid,baudrate or 115200,8,uart.PAR_NONE,uart.STOP_1)
    else
      uart.close(uartid)
    end
  end
  rtos.set_trace(v and 1 or 0,uartid)
end

function opntrace(v,uartid,baudrate)
  if opntrc.id == nil then
    opntrc.sta = v
    opntrc.id = uartid
    opntrc.rate = baudrate
    opnsettrace(v,uartid,baudrate)
  else
    if v == opntrc.sta then
      if uartid == opntrc.id and baudrate == opntrc.rate then
        print("opntrace invalid!")
      else
        opntrc.sta = v
        opntrc.id = uartid
        opntrc.rate = baudrate
        opnsettrace(v,uartid,baudrate)
      end
    else
      print("opntrace invalid!")
    end
  end
end

--应用消息分发,消息通知
local apps = {}

--[[
函数名：regapp
功能  ：注册app
参数  ：可变参数，app的参数，有以下两种形式：
		以函数方式注册的app，例如regapp(fncname,"MSG1","MSG2","MSG3")
		以table方式注册的app，例如regapp({MSG1=fnc1,MSG2=fnc2,MSG3=fnc3})
返回值：无
]]
function regapp(...)
	local app = arg[1]
	--table方式
	if type(app) == "table" then
	--函数方式
	elseif type(app) == "function" then
		app = {procer = arg[1],unpack(arg,2,arg.n)}
	else
		error("unknown app type "..type(app),2)
	end
	--产生一个增加app的内部消息
	dispatch("SYS_ADD_APP",app)
	return app
end

--[[
函数名：deregapp
功能  ：解注册app
参数  ：
		id：app的id，id共有两种方式，一种是函数名，另一种是table名
返回值：无
]]
function deregapp(id)
	--产生一个移除app的内部消息
	dispatch("SYS_REMOVE_APP",id)
end


--[[
函数名：addapp
功能  ：增加app
参数  ：
		app：某个app，有以下两种形式：
		     如果是以函数方式注册的app，例如regapp(fncname,"MSG1","MSG2","MSG3"),则形式为：{procer=arg[1],"MSG1","MSG2","MSG3"}
			 如果是以table方式注册的app，例如regapp({MSG1=fnc1,MSG2=fnc2,MSG3=fnc3}),则形式为{MSG1=fnc1,MSG2=fnc2,MSG3=fnc3}
返回值：无
]] 
local function addapp(app)
	-- 插入尾部
	table.insert(apps,#apps+1,app)
end

--[[
函数名：removeapp
功能  ：移除app
参数  ：
		id：app的id，id共有两种方式，一种是函数名，另一种是table名
返回值：无
]] 
local function removeapp(id)
	--遍历app表
	for k,v in ipairs(apps) do
		--app的id如果是函数名
		if type(id) == "function" then
			if v.procer == id then
				table.remove(apps,k)
				return
			end
		--app的id如果是table名
		elseif v == id then
			table.remove(apps,k)
			return
		end
	end
end

--[[
函数名：callapp
功能  ：处理内部消息
		通过遍历每个app进行处理
参数  ：
		msg：消息
返回值：无
]] 
local function callapp(msg)
	local id = msg[1]
	--增加app消息
	if id == "SYS_ADD_APP" then
		addapp(unpack(msg,2,#msg))
	--移除app消息
	elseif id == "SYS_REMOVE_APP" then
		removeapp(unpack(msg,2,#msg))
	else
		local app
		--遍历app表
		for i=#apps,1,-1 do
			app = apps[i]
      --函数注册方式的app,带id通知
			if app.procer then
				for _,v in ipairs(app) do
					if v == id then
						--如果消息的处理函数没有返回true，则此消息的生命期结束；否则一直遍历app
						if app.procer(unpack(msg)) ~= true then
							return
						end
					end
				end
      -- 处理表方式的app,不带id通知
			elseif app[id] then
				--如果消息的处理函数没有返回true，则此消息的生命期结束；否则一直遍历app
				if app[id](unpack(msg,2,#msg)) ~= true then
					return
				end
			end
		end
	end
end

--内部消息队列
local qmsg = {}

--[[
函数名：dispatch
功能  ：产生内部消息，存储在内部消息队列中
参数  ：可变参数，用户自定义
返回值：无
]] 
function dispatch(...)
	table.insert(qmsg,arg)
end

--[[
函数名：getmsg
功能  ：读取内部消息
参数  ：无
返回值：内部消息队列中的第一个消息，不存在则返回nil
]] 
local function getmsg()
	if #qmsg == 0 then
		return nil
	end

	return table.remove(qmsg,1)
end

--[[
函数名：runqmsg
功能  ：处理内部消息
参数  ：无
返回值：无
]] 
local function runqmsg()
	local inmsg
	while true do
		--读取内部消息
		inmsg = getmsg()
		--内部消息为空
		if  inmsg == nil then 
			--需要刷新界面
			if refreshflag == true then
				refreshflag=false
				--产生一个界面刷新内部消息
				inmsg={"UIWND_UPDATE"}
			else
				break
			end
		end
		--处理内部消息
		callapp(inmsg)
	end
end

--“除定时器消息、物理串口消息外的其他外部消息（例如AT命令的虚拟串口数据接收消息、音频消息、充电管理消息、按键消息等）”的处理函数表
local handlers = {}
base.setmetatable(handlers,{__index = function() return function() end end,})

--[[
函数名：regmsg
功能  ：注册“除定时器消息、物理串口消息外的其他外部消息（例如AT命令的虚拟串口数据接收消息、音频消息、充电管理消息、按键消息等）”的处理函数
参数  ：
		id：消息类型id
		handler：消息处理函数
返回值：无
]] 
function regmsg(id,handler)
	if not id then return end
	handlers[id] = handler
end

--各个物理串口的数据接收处理函数表
local uartprocs = {}

--[[
函数名：reguart
功能  ：注册物理串口的数据接收处理函数
参数  ：
		id：物理串口号，1表示UART1，2表示UART2
		fnc：数据接收处理函数名
返回值：无
]] 
function reguart(id,fnc)
	uartprocs[id-1] = fnc
end

--[[
函数名：run
功能  ：lua应用程序运行框架入口
参数  ：无
返回值：无

运行框架基于消息处理机制，目前一共两种消息：内部消息和外部消息
内部消息：lua脚本调用本文件dispatch接口产生的消息，消息存储在qmsg表中
外部消息：底层core软件产生的消息，lua脚本通过rtos.receive接口读取这些外部消息
]] 
function run()
	local msg,v1,v2,v3,v4

	while true do
		--处理内部消息
		runqmsg()
		--阻塞读取外部消息
		msg,v1,v2,v3,v4 = rtos.receive(rtos.INF_TIMEOUT)
		if msg then watchdog.kick() end

		--电池电量为0%，用户应用脚本中没有定义“低电关机处理程序”，并且没有启动自动关机定时器		
		if not lprfun and not lpring and type(msg) == "table" and msg.id == rtos.MSG_PMD and msg.level == 0 then
			--启动自动关机定时器，60秒后关机
			lpring = true
			timer_start(poweroff,60000,"r1")
		end
		
		--外部消息为table类型
		if type(msg) == "table" then
			--定时器类型消息
			if msg.id == rtos.MSG_TIMER then
				timerfnc(msg.timer_id)
			--AT命令的虚拟串口数据接收消息
			elseif msg.id == rtos.MSG_UART_RXDATA and msg.uart_id == uart.ATC then
				handlers.atc()
			else
				--物理串口数据接收消息
				if msg.id == rtos.MSG_UART_RXDATA then
					if uartprocs[msg.uart_id] ~= nil then
						uartprocs[msg.uart_id]()
					else
						handlers[msg.id](msg)
					end
				--其他消息（音频消息、充电管理消息、按键消息等）
				else
					handlers[msg.id](msg)
				end
			end
		--外部消息非table类型
		elseif type(msg) == "number" then
			--定时器类型消息
			if msg == rtos.MSG_TIMER then
				timerfnc(v1)
			elseif msg == rtos.MSG_ALARM then
				--print("ZHY rtos.MSG_ALARM",msg,rtos.MSG_ALARM,type(msg))
				handlers[msg](msg)
			elseif msg == rtos.MSG_UART_RXDATA then
				--AT命令的虚拟串口
				if v1 == uart.ATC then
					handlers.atc()
				--物理串口
				else
					if uartprocs[v1] ~= nil then
						uartprocs[v1]()
					else
						handlers[msg](msg,v1)
					end
				end
			elseif msg >= rtos.MSG_PDP_ACT_CNF and msg <= rtos.MSG_SOCK_CLOSE_IND then
				handlers.sock(msg,v1,v2,v3,v4)
			else
				if handlers[msg] then
					handlers[msg](v1,v2,v3,v4)
				end
			end
		end
		--打印lua脚本程序占用的内存，单位是K字节
		--print("mem:",base.collectgarbage("count"))
	end
end

local DIR,DIR2 = "/EPO_GR_3_","/QG_R_"
function removegpsdat()
	--timer_stop(removegpsdat)
	--timer_start(removegpsdat,3600*1000)
	for i = 0,10 do
		--print("removegpsdat",i,DIR..i..".DAT")
		os.remove(DIR..i..".DAT")
	end
	for i = 0,4 do
		os.remove(DIR2..i..".DAT")		
	end
end

--timer_start(removegpsdat,3600*1000)

if rtos.poweron_reason() == 0 then
  pio.pin.setdir(pio.OUTPUT,pio.P1_3)
  pio.pin.setval(1,pio.P1_3)
end
