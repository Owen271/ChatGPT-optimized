Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = """" & folder & "\Launch ChatGPT Optimized.cmd" & """"
shell.Run cmd, 0, False
