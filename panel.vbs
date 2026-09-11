' Starts panel.ps1 with no console window at all.
'
' "powershell -WindowStyle Hidden" is not enough on Windows 11: the console host
' is allocated before the style is applied, and when Windows Terminal is the
' default host it leaves an empty tab sitting there. WScript.Shell.Run with
' window style 0 starts the process genuinely hidden instead.
'
' Any arguments given here are passed straight through to panel.ps1, so
'   wscript panel.vbs -StartMirror -ScreenOff
' behaves like calling the script with those switches.

Option Explicit

Dim shell, fso, here, extra, i, command

Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)

extra = ""
For i = 0 To WScript.Arguments.Count - 1
    extra = extra & " " & WScript.Arguments(i)
Next

command = "powershell -NoProfile -ExecutionPolicy Bypass -File """ & _
          here & "\panel.ps1""" & extra

' 0 = hidden, False = do not wait for it to finish
shell.Run command, 0, False
