from collections import defaultdict

import sublime 
import sublime_plugin
    # { "keys": ["alt+up"], "command": "multi_tabs_next"},
    # { "keys": ["alt+down"], "command": "multi_tabs_next", "args": { "increase": -1 }},
    # { "keys": ["f8"], "command": "multi_tabs"},
    # { "keys": ["shift+f8"], "command": "multi_tabs", "args": { "increase": -1 }},
    # { "keys": ["alt+shift+down"], "command": "multi_tabs_switch"},

enabled_map = defaultdict(lambda: True)
# enabled_map = defaultdict(lambda: True)
enabled_group = defaultdict(lambda: True)
rows_map = defaultdict(lambda: -1)
max_rows = 4
#modify this parameter to configure height of tab rows
bar_height = 0.027
view_stat = defaultdict(lambda: {})
last_view_group = defaultdict(lambda: [0, 0])

row_cells_map = [
    [{"cols": [0.0 ,1],"rows": [0.0, 1.0],"cells": [[0, 0, 1, 1]]}],
    [
        {"cols": [0.0 ,1],"rows": [0.0, bar_height, bar_height*2, 1.0],"cells": [[0, 1, 1, 3],[0, 0, 1, 1]]},
        {"cols": [0.0 ,1],"rows": [0.0, bar_height, bar_height*2, 1.0],"cells": [[0, 0, 1, 1],[0, 1, 1, 3]]},
    ],
    [
        {"cols": [0.0 ,1],"rows": [0.0, bar_height, bar_height*2, 1.0],"cells": [[0, 2, 1, 3],[0, 0, 1, 1],[0, 1, 1, 2]]},
        {"cols": [0.0 ,1],"rows": [0.0, bar_height, bar_height*2, 1.0],"cells": [[0, 1, 1, 2],[0, 2, 1, 3],[0, 0, 1, 1]]},
        {"cols": [0.0 ,1],"rows": [0.0, bar_height, bar_height*2, 1.0],"cells": [[0, 0, 1, 1],[0, 1, 1, 2],[0, 2, 1, 3]]}
    ],
    [
        {"cols": [0.0, 1],"rows": [0.0, bar_height, bar_height*2, bar_height*3, 1.0],"cells": [[0, 3, 1, 4], [0, 0, 1, 1], [0, 1, 1, 2], [0, 2, 1, 3]]},
        {"cols": [0.0, 1],"rows": [0.0, bar_height, bar_height*2, bar_height*3, 1.0],"cells": [[0, 2, 1, 3], [0, 3, 1, 4], [0, 0, 1, 1], [0, 1, 1, 2]]},
        {"cols": [0.0, 1],"rows": [0.0, bar_height, bar_height*2, bar_height*3, 1.0],"cells": [[0, 1, 1, 2], [0, 2, 1, 3], [0, 3, 1, 4], [0, 0, 1, 1]]},
        {"cols": [0.0, 1],"rows": [0.0, bar_height, bar_height*2, bar_height*3, 1.0],"cells": [[0, 0, 1, 1], [0, 1, 1, 2], [0, 2, 1, 3],[0, 3, 1, 4]]},
    ],
]

def layout_rows(window, group, id_):
    enabled_group[id_] = group
    window.run_command("set_layout", row_cells_map[rows_map[id_]][group])
    view_stat[id_] = {"gnum": window.num_groups(), "g": group}


def last_view(window, group, id_):
    if group != window.get_view_index(window.active_view())[0]:
        return

    if group not in last_view_group[id_]:
        last_view_group[id_][0] = last_view_group[id_][1]
        last_view_group[id_][1] = group


class MultiColumnTabBarCommand(sublime_plugin.EventListener):
    def on_activated(self, view):
        # sublime.active_window().num_groups()
        id_ = view.window().id()
        # if not enabled_map[id_]:
        #    return
        window = view.window()
        # group, _ = window.get_view_index(view)
        group, _ = window.get_view_index(window.active_view())
        gnum = sublime.active_window().num_groups()

        if rows_map[id_] == -1:
            rows_map[id_] = gnum - 1
            
        sublime.set_timeout(lambda : last_view(window, group, id_), 500)


        if view_stat.get(id_) and view_stat[id_]['gnum'] == gnum and view_stat[id_]['g'] == group:
            return

        layout_rows(window, group, id_)

class MultiTabsCommand(sublime_plugin.WindowCommand):
    def run(self, increase = 1):
        # sublime.error_message('git_executable_not_found')
        id_ = self.window.id()
        
        if increase > 0 and sublime.active_window().num_groups() == max_rows:
            return

        if increase < 0 and sublime.active_window().num_groups() == 1:
            return
        
        rows = (self.window.num_groups() - 1) + increase
        rows_map[id_] = rows % max_rows
        if rows_map[id_] == 0:
            enabled_map[id_] = False
        else:
            enabled_map[id_] = True
        
        layout_rows(self.window, 0, id_)


class MultiTabsSwitchCommand(sublime_plugin.WindowCommand):
    def run(self):
        window = self.window
        id_ = window.id()
        group, _ = window.get_view_index(window.active_view())
        
        if last_view_group[id_][0] == group and last_view_group[id_][1] <= window.num_groups() - 1:
            layout_rows(self.window, last_view_group[id_][1], id_)
        elif last_view_group[id_][1] == group and last_view_group[id_][0] <= window.num_groups() - 1:
            layout_rows(self.window, last_view_group[id_][0], id_)
        
        self.window.run_command('focus_group', {'group': enabled_group[id_]})

class MultiTabsNextCommand(sublime_plugin.WindowCommand):
    def run(self, increase = 1):
        id_ = self.window.id()
        #if not enabled_map[id_]:
        #    return
        #group = enabled_group[id_] + 1
        group, _ = sublime.active_window().get_view_index(self.window.active_view())
        enabled_group[id_] = (group + increase)% self.window.num_groups()
        layout_rows(self.window, enabled_group[id_], id_)
        self.window.run_command('focus_group', {'group': enabled_group[id_]})


class TabsNextCommand(sublime_plugin.WindowCommand):
    def run(self, increase = 1):
        group, _ = sublime.active_window().get_view_index(self.window.active_view())
        view_len = len(sublime.active_window().views_in_group(group)) - 1
        
        _ = _ + increase
        if _ < 0:
            _ = 0
        if _ > view_len:
            _ = view_len

        self.window.run_command('select_by_index', {'index': _})

class ToggleMultiColLayoutCommand(sublime_plugin.WindowCommand):
    def run(self):
        id_ = self.window.id()
        enabled_map[id_] ^= True
        if enabled_map[id_]:
            print("Multi Column switch enabled")
        else:
            print("Multi Column switch disabled")

        
class ToggleMultiColLayoutCommand(sublime_plugin.WindowCommand):
    def run(self):
        id_ = self.window.id()
        enabled_map[id_] ^= True
        if enabled_map[id_]:
            print("Multi Column switch enabled")
        else:
            print("Multi Column switch disabled")
           
            
class DisableMultiColLayoutCommand(sublime_plugin.WindowCommand):
    def run(self):
        id_ = self.window.id()
        enabled_map[id_] = False
        print("Multi Column switch disabled")


class EnableMultiColLayoutCommand(sublime_plugin.WindowCommand):
    def run(self):
        id_ = self.window.id()
        enabled_map[id_] = True
        print("Multi Column switch enabled")


class ResetLayoutCommand(sublime_plugin.WindowCommand):
    def run(self):
        id_ = self.window.id()

        if enabled_map[id_] == False:
            self.window.run_command("toggle_multi_col_layout")
            layout_rows(self.window, 0, id_)
        else:
            enabled_map[id_] = False
            self.window.run_command("set_layout",{"cols": [0.0 ,1],"rows": [0.0, 1.0],"cells": [[0, 0, 1, 1]]})
            print("Multi Column disabled and layout reset to standard")

