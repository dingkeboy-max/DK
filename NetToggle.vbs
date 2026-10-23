Dim fso, shell, scriptPath
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
scriptPath = fso.GetParentFolderName(WScript.ScriptFullName) & "\NetToggle.ps1"
' intWindowStyle=0 完全隐藏控制台；UAC 提示与程序窗口仍正常出现
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & scriptPath & """", 0, False
