#pragma once

#include "SDL_compat.h"

#include <vector>

class Session;

// In-stream menu for handheld and touch devices. A four-finger tap (or the
// Start+Select+L1+R1 gamepad combo) opens it; it is driven by touch, gamepad,
// keyboard or mouse and is drawn by the video renderer as a centered overlay.
class StreamMenu
{
public:
    explicit StreamMenu(Session* session);

    bool isOpen() const { return m_Open; }
    void open();
    void close();

    // Returns true if the event was consumed by the menu or its open gesture
    bool handleEvent(const SDL_Event& event);

private:
    enum Item {
        ItemResume,
        ItemToggleStats,
        ItemDisconnect,
        ItemQuitGame,
        ItemExit,
        ItemCount
    };

    // itemAt() results for positions that aren't on a menu row
    static constexpr int k_NotOnItem = -1;
    static constexpr int k_OutsideMenu = -2;

    bool handleFingerEvent(const SDL_TouchFingerEvent& event);
    void activate(int item);
    void moveSelection(int delta);
    void refresh();
    int itemAt(float normX, float normY);
    void getDrawableSize(int& width, int& height);
    void pushQuitEvent();

    Session* m_Session;
    bool m_Open;
    int m_Selected;
    int m_StickDirection;

    // Four-finger gesture tracking. Touches stay swallowed until every
    // finger of the gesture has lifted.
    std::vector<SDL_FingerID> m_ActiveFingers;
    uint32_t m_FirstFingerDownTime;
    bool m_SwallowTouches;

    // Single-finger selection while the menu is open
    bool m_TapActive;
    SDL_FingerID m_TapFinger;
    bool m_TapStartedOutside;
};
